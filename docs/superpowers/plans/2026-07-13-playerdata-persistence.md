# PlayerDataService DataStore Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `PlayerDataService`'s in-memory-only profile cache with real `DataStoreService`
persistence, so Coins/Mass/etc. survive a player leaving and rejoining, without changing any calling
code elsewhere in the codebase.

**Architecture:** `PlayerDataService.lua` gains three new internal helpers — `mergeWithDefaults`
(shallow-merges a loaded record over `DEFAULT_PROFILE` so missing fields get defaults without losing
saved values), `loadProfile` (pcall-wrapped `GetAsync` with retry/backoff, called on join), and
`saveProfile` (pcall-wrapped `UpdateAsync` with a caller-supplied retry budget, called on leave and on
shutdown). `onPlayerAdded` kicks the player if load fails after retries rather than letting them play
with unsaved progress. `onPlayerRemoving` saves with the full retry budget. A new `game:BindToClose`
handler saves every still-cached player concurrently with a shorter retry budget, bounded by an overall
timeout. The public interface (`Get`, `AddCoins`, `AddMass`, `Start`) is unchanged, so
`EconomyService.lua`, `FoodService.lua`, and everything else that touches currency needs zero changes.

**Tech Stack:** Luau (Roblox), `DataStoreService` (built-in, no external library — see the design
spec's discussion of why a session-locking library like ProfileService was explicitly rejected for this
stage), Roblox Studio MCP connection for live verification.

**No automated test framework exists in this repo** (no TestEZ, no CI), consistent with the prior
food-pickup-eat-loop plan. Every task's "test" step is: write the code, then exercise it live via the
Roblox Studio MCP `execute_luau` tool against a running Play-mode session, confirming output via
`get_console_output`. Treat it with the same rigor as an automated test — run it, confirm the exact
expected output, don't skip it.

## Global Constraints

- Server is the only authority: nothing outside `PlayerDataService` may touch `Cache` or `leaderstats`
  directly (unchanged from the existing rule).
- `UpdateAsync`, never `SetAsync`, for anything incremented (per this project's `CLAUDE.md`).
- DataStore writes wrapped in pcall with retry logic; a failed save must never silently lose player
  data without at least being logged (per `CLAUDE.md`).
- No periodic autosave — save-on-leave and save-on-shutdown only. Explicit user decision during
  brainstorming: "no need to overcomplicate the system at this stage."
- Load failure after retries → kick the player with a plain-language message. Never let them play with
  silently-unsaved progress. Explicit design decision — see the spec's Error Handling section.
- DataStore name `PlayerData_v1`, key format `Player_<UserId>` (see spec's Architecture section).
- PascalCase for scripts/modules, camelCase for variables/functions, ALL_CAPS for constants (per
  `CLAUDE.md`).

**Design spec:** `docs/superpowers/specs/2026-07-13-playerdata-persistence-design.md` — read this
first for full rationale, including the accepted-risk tradeoff of not using a session-locking library
and the reasoning behind kick-on-load-failure not being able to cascade into a persistent loop.

---

### Task 1: `PlayerDataService.lua` — DataStore load/save/shutdown persistence

**Files:**
- Modify: `src/ServerScriptService/Services/PlayerDataService.lua`

**Interfaces:**
- Consumes: nothing new — same as before (`Players` service only).
- Produces: `PlayerDataService.Start()`, `PlayerDataService.Get(player) -> PlayerProfile`,
  `PlayerDataService.AddCoins(player, amount)`, `PlayerDataService.AddMass(player, amount)` — all four
  signatures identical to the current version. `EconomyService.lua` and any future caller need no
  changes.

- [ ] **Step 1: Replace the full contents of `PlayerDataService.lua`**

`src/ServerScriptService/Services/PlayerDataService.lua`:
```lua
-- PlayerDataService.lua
-- Sole owner of the in-memory PlayerProfile cache, leaderstats, and DataStore persistence.
-- No other script reads/writes the cache, leaderstats, or the DataStore directly.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local PlayerDataService = {}

local DATASTORE_NAME = "PlayerData_v1"
local KEY_PREFIX = "Player_"

local LOAD_SAVE_RETRY_COUNT = 3
local LOAD_SAVE_RETRY_BACKOFF_SEC = { 1, 2, 4 }
local SHUTDOWN_RETRY_COUNT = 1
local SHUTDOWN_TIMEOUT_SEC = 25

local PlayerDataStore = DataStoreService:GetDataStore(DATASTORE_NAME)

local DEFAULT_PROFILE = {
	Version = 1,
	Coins = 0,
	Mass = 0,
	RebirthCount = 0,
	UnlockedZones = { 1 },
	OwnedPets = {},
	EquippedPet = nil,
	OwnedAuras = {},
	EquippedAura = nil,
	OwnedTitles = {},
	EquippedTitle = nil,
	GamepassCache = {},
}

local Cache = {}

local function copyDefaultProfile()
	local profile = {}
	for key, value in DEFAULT_PROFILE do
		if type(value) == "table" then
			profile[key] = table.clone(value)
		else
			profile[key] = value
		end
	end
	return profile
end

local function mergeWithDefaults(saved)
	local profile = copyDefaultProfile()
	for key in DEFAULT_PROFILE do
		if saved[key] ~= nil then
			profile[key] = saved[key]
		end
	end
	return profile
end

local function profileKey(userId)
	return KEY_PREFIX .. tostring(userId)
end

-- Returns (profile, success). success is false only after every retry attempt errored.
local function loadProfile(userId)
	local key = profileKey(userId)

	for attempt = 1, LOAD_SAVE_RETRY_COUNT do
		local ok, result = pcall(function()
			return PlayerDataStore:GetAsync(key)
		end)

		if ok then
			if result == nil then
				return copyDefaultProfile(), true
			end
			return mergeWithDefaults(result), true
		end

		warn(
			("[PlayerDataService] GetAsync failed for %s (attempt %d/%d): %s"):format(
				key,
				attempt,
				LOAD_SAVE_RETRY_COUNT,
				tostring(result)
			)
		)

		if attempt < LOAD_SAVE_RETRY_COUNT then
			task.wait(LOAD_SAVE_RETRY_BACKOFF_SEC[attempt])
		end
	end

	return nil, false
end

-- Returns success. backoffSeconds may be nil to retry with no delay between attempts.
local function saveProfile(userId, profile, retryCount, backoffSeconds)
	local key = profileKey(userId)

	for attempt = 1, retryCount do
		local ok, err = pcall(function()
			PlayerDataStore:UpdateAsync(key, function()
				return profile
			end)
		end)

		if ok then
			return true
		end

		warn(
			("[PlayerDataService] UpdateAsync failed for %s (attempt %d/%d): %s"):format(
				key,
				attempt,
				retryCount,
				tostring(err)
			)
		)

		if backoffSeconds and attempt < retryCount then
			task.wait(backoffSeconds[attempt])
		end
	end

	return false
end

local function createLeaderstats(player, profile)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = profile.Coins
	coins.Parent = leaderstats

	local mass = Instance.new("NumberValue")
	mass.Name = "Mass"
	mass.Value = profile.Mass
	mass.Parent = leaderstats

	leaderstats.Parent = player
end

local function onPlayerAdded(player)
	local profile, success = loadProfile(player.UserId)

	if not success then
		warn(
			("[PlayerDataService] Failed to load save data for %s (%d) after retries — kicking."):format(
				player.Name,
				player.UserId
			)
		)
		player:Kick("Couldn't load your save data — please try rejoining.")
		return
	end

	Cache[player.UserId] = profile
	createLeaderstats(player, profile)
end

local function onPlayerRemoving(player)
	local profile = Cache[player.UserId]

	if profile then
		local success = saveProfile(player.UserId, profile, LOAD_SAVE_RETRY_COUNT, LOAD_SAVE_RETRY_BACKOFF_SEC)
		if not success then
			warn(
				("[PlayerDataService] Failed to save data for %s (%d) after retries — data may be lost."):format(
					player.Name,
					player.UserId
				)
			)
		end
	end

	Cache[player.UserId] = nil
end

local function onShutdown()
	local pending = 0

	for userId, profile in Cache do
		pending += 1
		task.spawn(function()
			local success = saveProfile(userId, profile, SHUTDOWN_RETRY_COUNT, nil)
			if not success then
				warn(("[PlayerDataService] Shutdown save failed for UserId %d"):format(userId))
			end
			pending -= 1
		end)
	end

	local deadline = os.clock() + SHUTDOWN_TIMEOUT_SEC
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end

function PlayerDataService.Get(player)
	return Cache[player.UserId]
end

function PlayerDataService.AddCoins(player, amount)
	local profile = Cache[player.UserId]
	if not profile then
		return
	end
	profile.Coins += amount
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		leaderstats.Coins.Value = profile.Coins
	end
end

function PlayerDataService.AddMass(player, amount)
	local profile = Cache[player.UserId]
	if not profile then
		return
	end
	profile.Mass += amount
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		leaderstats.Mass.Value = profile.Mass
	end
end

function PlayerDataService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	game:BindToClose(onShutdown)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return PlayerDataService
```

- [ ] **Step 2: Verify new-player load and in-session behavior unchanged**

`Init.server.lua` already calls `PlayerDataService.Start()` at server boot (wired in the food-loop
plan), so starting Play mode alone triggers `onPlayerAdded` → `loadProfile` for the test player via a
real `GetAsync` call. Start Play mode via the Roblox Studio MCP `start_stop_play` tool, then run via
`execute_luau`:
```lua
local Players = game:GetService("Players")
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)

local player = Players:GetPlayers()[1]
assert(player, "No test player in this Play session")

local profile = PlayerDataService.Get(player)
print("New player Coins:", profile.Coins, "(expected 0)")
print("New player Mass:", profile.Mass, "(expected 0)")
print("New player UnlockedZones[1]:", profile.UnlockedZones[1], "(expected 1)")
print("leaderstats exists:", player:FindFirstChild("leaderstats") ~= nil, "(expected true)")

PlayerDataService.AddCoins(player, 37)
PlayerDataService.AddMass(player, 4.2)

print("After add, Coins:", PlayerDataService.Get(player).Coins, "(expected 37)")
print("After add, leaderstats Coins:", player.leaderstats.Coins.Value, "(expected 37)")
print("After add, Mass:", PlayerDataService.Get(player).Mass, "(expected 4.2)")
```
Expected output: `New player Coins: 0 (expected 0)`, `New player Mass: 0 (expected 0)`,
`New player UnlockedZones[1]: 1 (expected 1)`, `leaderstats exists: true (expected true)`,
`After add, Coins: 37 (expected 37)`, `After add, leaderstats Coins: 37 (expected 37)`,
`After add, Mass: 4.2 (expected 4.2)`. Confirm via `get_console_output`, with no unexpected warnings.

If this is the very first time this UserId has ever been used with the `PlayerData_v1` DataStore in
this place, `GetAsync` returning `nil` is expected and correct — that's the new-player path. If a
warning about `GetAsync failed` appears here, stop and check that "Studio Access to API Services" is
enabled in Game Settings → Security (see the design spec's Testing section) before continuing.

- [ ] **Step 3: Verify the real save → reload persistence cycle (the spec's acceptance test)**

With Play mode still running from Step 2 (so the 37 Coins / 4.2 Mass from Step 2 are still in `Cache`),
stop Play mode via `start_stop_play`. This fires `PlayerRemoving` for the test player (and/or
`BindToClose`, since Studio treats stopping Play mode as a full server shutdown — either path calls
the same `saveProfile` function, so which one actually fires doesn't change what's being verified
here).

Start Play mode again (a fresh server, same test player/UserId), then run via `execute_luau`:
```lua
local Players = game:GetService("Players")
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)

local player = Players:GetPlayers()[1]
assert(player, "No test player in this Play session")

local profile = PlayerDataService.Get(player)
print("Reloaded Coins:", profile.Coins, "(expected 37)")
print("Reloaded Mass:", profile.Mass, "(expected 4.2)")
print("Reloaded leaderstats Coins:", player.leaderstats.Coins.Value, "(expected 37)")
```
Expected output: `Reloaded Coins: 37 (expected 37)`, `Reloaded Mass: 4.2 (expected 4.2)`,
`Reloaded leaderstats Coins: 37 (expected 37)`. Confirm via `get_console_output`. This confirms the
full join → earn → leave/shutdown-save → rejoin → load-with-merge cycle works against real Studio
DataStore access, which is this task's real acceptance test per the design spec.

Leave Play mode running (or stop it) — either is fine for the next step.

- [ ] **Step 4: Note the untestable failure path rather than skip it silently**

The kick-on-load-failure and warn-on-save-failure paths (triggered only when every retry attempt
errors) cannot be triggered live in Studio — there is no supported way to force a real
`DataStoreService` outage on demand, and Studio's local DataStore access does not expose a fault
-injection hook. This path was implemented per the design spec's exact retry/backoff/kick policy
(Step 1's `loadProfile`/`saveProfile`/`onPlayerAdded`) and is being verified by code inspection only —
confirm by rereading `loadProfile` and `onPlayerAdded` above that: (a) `player:Kick(...)` is only
reached after all `LOAD_SAVE_RETRY_COUNT` attempts fail, (b) a successful attempt at any point returns
immediately without kicking, (c) the warning message includes the player's name and UserId so a real
occurrence would be diagnosable in the server console. Do not claim this path was live-tested — it
wasn't, and can't be with the tools available here.

- [ ] **Step 5: Commit**

```bash
git add src/ServerScriptService/Services/PlayerDataService.lua
git commit -m "Add DataStore persistence to PlayerDataService (load/save/shutdown)"
```

---

### Task 2: Update this project's `CLAUDE.md` to reflect real persistence

**Files:**
- Modify: `CLAUDE.md` (the "Roblox Eating Game" one, at the repo root)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing — documentation only, required per this project's own instructions ("this file
  should always reflect the current source of truth, not the original plan").

- [ ] **Step 1: Update the Project Structure section**

Find this line in `CLAUDE.md`:
```
      PlayerDataService.lua   -- owns the in-memory PlayerProfile cache + leaderstats (DataStore I/O deferred)
```

Replace it with:
```
      PlayerDataService.lua   -- owns the PlayerProfile cache, leaderstats, and DataStore persistence
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md to reflect real PlayerDataService persistence"
```

---

## Self-Review Notes

**Spec coverage:** DataStore name/key format (Task 1 Step 1, `DATASTORE_NAME`/`KEY_PREFIX`), load with
retry+backoff+merge (Task 1 Step 1, `loadProfile`/`mergeWithDefaults`), kick-on-load-failure (Task 1
Step 1, `onPlayerAdded`; verified by inspection in Step 4 per the spec's own acknowledgment that this
path can't be forced live), save-on-leave with full retry budget (Task 1 Step 1, `onPlayerRemoving`),
save-on-shutdown with concurrent saves + shorter retry + timeout ceiling (Task 1 Step 1, `onShutdown`),
`UpdateAsync` not `SetAsync` (Task 1 Step 1, `saveProfile`), unchanged public interface (Task 1's
Interfaces block — `Get`/`AddCoins`/`AddMass`/`Start` signatures identical), no periodic autosave (no
task adds one), CLAUDE.md kept current (Task 2). All spec sections have a corresponding task.

**Placeholder scan:** no TBD/TODO left in the plan. The one explicitly-unverifiable path (load/save
failure after exhausted retries) is documented as such rather than glossed over, per this plan's own
Step 4 — that's an honest scope note, not a placeholder.

**Type consistency:** `PlayerDataService.Get(player)`, `.AddCoins(player, amount)`,
`.AddMass(player, amount)`, `.Start()` are identical to the pre-existing signatures referenced in the
food-pickup-eat-loop plan's Task 3 (`EconomyService` calls `AddCoins`/`AddMass`) — no caller-facing
change, confirmed by re-reading `EconomyService.lua`'s existing `require(script.Parent.PlayerDataService)`
usage, which needs no edits under this plan.
