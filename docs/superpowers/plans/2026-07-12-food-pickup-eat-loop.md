# Food Pickup → Hotbar → Eat Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first working end-to-end gameplay loop — a player picks up a Zone 1 Broccoli food
item from a table (Roblox `Tool`, via `ProximityPrompt`), equips it in their hotbar, and clicks to eat
it repeatedly, gaining Coins and Mass shown on the leaderboard.

**Architecture:** A new `FoodService` (server) owns pickup (`ProximityPromptService.PromptTriggered`)
and eat (`Tool.Activated`) wiring, both of which Roblox fires **server-side natively** — no custom
RemoteEvents needed for either signal. `FoodService` delegates all currency math to `EconomyService`,
which is the sole owner of Coin/Mass grants and reads amounts from the existing `ZoneConfig.lua`.
`PlayerDataService` owns an in-memory `PlayerProfile` cache plus the `leaderstats` Roblox UI mirror,
structured so real DataStore persistence can be added later without any caller changing. Placeholder
world objects (the food table, the food Tool) are authored as git-tracked Rojo `.model.json` files,
not built live in Studio, so a future session can read exactly what exists in the world from the repo
alone.

**Tech Stack:** Luau (Roblox), Rojo 7.7.0 (confirmed running locally, synced to the `RobloxEatingGame`
Studio instance on the default port), Roblox Studio MCP connection for live verification.

**No automated test framework exists in this repo** (no TestEZ, no CI). Per this project's own
priorities ("fast turnaround," don't add tooling that isn't needed), this plan does **not** introduce
one. Every task's "test" step is: write the code, then exercise it live via the Roblox Studio MCP
`execute_luau` tool against a running Play-mode session, and confirm the printed output via
`get_console_output`. This is the project's real verification mechanism — treat it with the same rigor
as an automated test (write the check, run it, confirm the exact expected output, don't skip it).

## Global Constraints

- Server is the only authority: Coin/Mass grants only ever happen inside `EconomyService`; nothing
  else mutates `leaderstats` or the profile cache directly.
- Never hardcode zone numbers (Coins/bite, Mass/bite, food name) in logic scripts — always read from
  `ZoneConfig.lua`.
- Use `UpdateAsync`-style incremental patterns for anything that will eventually hit a DataStore — not
  relevant yet since persistence is explicitly deferred, but the in-memory API shape must not preclude
  it later.
- PascalCase for scripts/modules, camelCase for variables/functions, ALL_CAPS for constants in config
  modules (per this project's `CLAUDE.md`).
- No script outside `PlayerDataService` may touch the profile cache or `leaderstats` directly; no
  script outside `EconomyService` may call `PlayerDataService.AddCoins`/`AddMass`.
- Tool is never destroyed/consumed on eat. Cooldown is tracked per-player (`UserId`), never per-tool,
  so swapping tools cannot bypass it.
- Zone-unlock gating, multiple food types per zone, real DataStore persistence, eating animations, and
  gamepass multipliers are explicitly out of scope for this plan (see the design spec).

**Design spec:** `docs/superpowers/specs/2026-07-12-food-pickup-eat-loop-design.md` — read this first
for the full rationale behind every decision below.

**Amendment discovered during implementation:** Rojo's `.model.json` format does not apply
`Attributes` from the JSON file in this project's environment (confirmed by inspecting Rojo's own
server-side synced tree directly, not just Studio). Regular `Properties` sync fine. `ZoneId` attributes
are therefore set **programmatically** via `Instance:SetAttribute` in `Init.server.lua` (Task 5) instead
of being authored in the `.model.json` files (Task 1). See the spec's Amendment section for full detail.
This changes Task 1 (no `Attributes` key in either `.model.json`) and Task 5 (adds the attribute
bootstrap) from what's below in a few places — those tasks have been updated accordingly; Tasks 2, 3,
and 6 are unaffected.

---

### Task 1: Placeholder world objects — Workspace Rojo mapping, food table, food tool

**Files:**
- Modify: `default.project.json`
- Create: `src/Workspace/FoodTables/Zone1Table.model.json`
- Create: `src/ReplicatedStorage/Assets/FoodTools/Broccoli.model.json`

**Interfaces:**
- Produces: `Workspace.FoodTables.Zone1Table` (a `Part` with a child `ProximityPrompt` named
  `PickupPrompt`), and `ReplicatedStorage.Assets.FoodTools.Broccoli` (a `Tool` with a child `Part`
  named `Handle`). Neither has a `ZoneId` attribute yet — Rojo's `.model.json` format does not apply
  `Attributes` in this environment (confirmed by inspecting Rojo's own synced tree; see the plan
  header's Amendment note). Task 5's `Init.server.lua` sets `ZoneId = 1` on both via
  `Instance:SetAttribute` at server boot instead. Later tasks (`FoodService`) read that attribute at
  runtime and clone the `Tool` by name — they don't care how the attribute got set, only that it's
  present by the time they run.

- [ ] **Step 1: Add the Workspace mapping to `default.project.json`**

Current content:
```json
{
  "name": "RobloxEatingGame",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": {
      "$path": "src/ServerScriptService"
    },
    "ReplicatedStorage": {
      "$path": "src/ReplicatedStorage"
    },
    "StarterPlayer": {
      "StarterPlayerScripts": {
        "$path": "src/StarterPlayer/StarterPlayerScripts"
      }
    }
  }
}
```

Replace with:
```json
{
  "name": "RobloxEatingGame",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": {
      "$path": "src/ServerScriptService"
    },
    "ReplicatedStorage": {
      "$path": "src/ReplicatedStorage"
    },
    "StarterPlayer": {
      "StarterPlayerScripts": {
        "$path": "src/StarterPlayer/StarterPlayerScripts"
      }
    },
    "Workspace": {
      "$path": "src/Workspace"
    }
  }
}
```

- [ ] **Step 2: Confirm Rojo picked up the new mapping**

Rojo 7 watches `default.project.json` itself and should hot-reload this structural change. Check via:
```bash
curl -s http://localhost:34872/api/rojo
```
Expected: valid JSON response (same shape as before), no error. If the Studio Rojo plugin panel shows
a disconnected/error state after saving, restart `rojo serve` in the terminal it's running in (ask the
user to do this if you don't own that terminal process), then reconnect the plugin in Studio.

- [ ] **Step 3: Create the Zone 1 table placeholder**

`src/Workspace/FoodTables/Zone1Table.model.json`:
```json
{
  "Name": "Zone1Table",
  "ClassName": "Part",
  "Properties": {
    "Size": { "Vector3": [4, 1, 4] },
    "Position": { "Vector3": [10, 2.5, 10] },
    "Anchored": true,
    "CanCollide": true,
    "Color": { "Color3": [0.4, 0.25, 0.15] }
  },
  "Children": [
    {
      "Name": "PickupPrompt",
      "ClassName": "ProximityPrompt",
      "Properties": {
        "ActionText": "Pick Up",
        "ObjectText": "Broccoli",
        "MaxActivationDistance": 10
      }
    }
  ]
}
```

This is a placeholder position (floating slightly above a default baseplate) — expect to reposition it
visually in Studio later and copy the resulting `Position` back into this file, per the design spec's
note on keeping live Studio edits in sync with git.

- [ ] **Step 4: Create the Broccoli Tool placeholder**

`src/ReplicatedStorage/Assets/FoodTools/Broccoli.model.json`:
```json
{
  "Name": "Broccoli",
  "ClassName": "Tool",
  "Properties": {
    "RequiresHandle": true,
    "CanBeDropped": false
  },
  "Children": [
    {
      "Name": "Handle",
      "ClassName": "Part",
      "Properties": {
        "Size": { "Vector3": [1, 1, 1] },
        "Anchored": false,
        "CanCollide": false,
        "Color": { "Color3": [0.13, 0.55, 0.13] }
      }
    }
  ]
}
```

`CanBeDropped = false` is deliberate: `FoodService` (Task 4) only ever looks for food Tools in a
player's `Backpack` or equipped `Character`, not in `Workspace`. If a tool could be dropped into the
world, it would become untracked and unreplaceable by the pickup-replace logic.

- [ ] **Step 5: Verify both instances synced correctly**

Use the Roblox Studio MCP `execute_luau` tool to run:
```lua
local table1 = workspace:FindFirstChild("FoodTables") and workspace.FoodTables:FindFirstChild("Zone1Table")
print("Table exists:", table1 ~= nil)
print("Table has prompt:", table1 and table1:FindFirstChild("PickupPrompt") ~= nil)

local tool = game.ReplicatedStorage:FindFirstChild("Assets")
	and game.ReplicatedStorage.Assets:FindFirstChild("FoodTools")
	and game.ReplicatedStorage.Assets.FoodTools:FindFirstChild("Broccoli")
print("Tool exists:", tool ~= nil)
print("Tool ClassName:", tool and tool.ClassName)
print("Tool has Handle:", tool and tool:FindFirstChild("Handle") ~= nil)
```
Expected output: `Table exists: true`, `Table has prompt: true`, `Tool exists: true`,
`Tool ClassName: Tool`, `Tool has Handle: true`. Do NOT check `ZoneId` here — it isn't set until
Task 5's `Init.server.lua` runs; that's expected, not a bug.

If any property failed to apply (e.g. `Size`/`Position`/`Color` came through as zero/default instead
of the values above), check the terminal running `rojo serve` for a property deserialization error.
Rojo's JSON model format expects the `{"Vector3": [...]}` / `{"Color3": [...]}` wrapper shown above for
non-scalar property types — if that's already present and still failing, retry with the bare-array
form (`"Size": [4, 1, 4]`) instead, since the exact expected encoding can vary by Rojo version. Also
confirm your changes are actually live-syncing at all: change an unrelated property (e.g. `Color`),
wait a few seconds, and re-check it in Studio. If it never updates, Rojo/Studio need a restart and
plugin reconnect before you can trust any further verification in this task — don't proceed on stale
data.

- [ ] **Step 6: Commit**

```bash
git add default.project.json src/Workspace/FoodTables/Zone1Table.model.json src/ReplicatedStorage/Assets/FoodTools/Broccoli.model.json
git commit -m "Add Workspace Rojo mapping and Zone 1 food table/tool placeholders"
```

---

### Task 2: `PlayerDataService.lua` — in-memory profile cache + leaderstats

**Files:**
- Modify: `src/ServerScriptService/Services/PlayerDataService.lua`

**Interfaces:**
- Consumes: nothing (base service).
- Produces: `PlayerDataService.Start()`, `PlayerDataService.Get(player: Player) -> PlayerProfile`,
  `PlayerDataService.AddCoins(player: Player, amount: number)`,
  `PlayerDataService.AddMass(player: Player, amount: number)`. `EconomyService` (Task 3) calls
  `AddCoins`/`AddMass`; nothing else may.

- [ ] **Step 1: Implement the service**

Replace the full contents of `src/ServerScriptService/Services/PlayerDataService.lua` with:
```lua
-- PlayerDataService.lua
-- Sole owner of the in-memory PlayerProfile cache and leaderstats.
-- No other script reads/writes the cache or leaderstats directly.
-- Persistence (real DataStore save/load) is deferred; only this module will change when it's added.

local Players = game:GetService("Players")

local PlayerDataService = {}

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
	local profile = copyDefaultProfile()
	Cache[player.UserId] = profile
	createLeaderstats(player, profile)
end

local function onPlayerRemoving(player)
	-- TODO: flush profile to DataStore here once PlayerDataService owns real persistence.
	Cache[player.UserId] = nil
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

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return PlayerDataService
```

- [ ] **Step 2: Verify in a live Play session**

Start Play mode via the Roblox Studio MCP `start_stop_play` tool if it isn't already running, then run
via `execute_luau`:
```lua
local Players = game:GetService("Players")
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)

PlayerDataService.Start()

local player = Players:GetPlayers()[1]
assert(player, "No test player in this Play session")

print("leaderstats exists:", player:FindFirstChild("leaderstats") ~= nil)
print("Initial Coins:", PlayerDataService.Get(player).Coins)
print("Initial Mass:", PlayerDataService.Get(player).Mass)

PlayerDataService.AddCoins(player, 5)
PlayerDataService.AddMass(player, 0.5)

print("After add, profile Coins:", PlayerDataService.Get(player).Coins)
print("After add, leaderstats Coins:", player.leaderstats.Coins.Value)
print("After add, profile Mass:", PlayerDataService.Get(player).Mass)
print("After add, leaderstats Mass:", player.leaderstats.Mass.Value)
```
Expected output: `leaderstats exists: true`, `Initial Coins: 0`, `Initial Mass: 0`,
`After add, profile Coins: 5`, `After add, leaderstats Coins: 5`, `After add, profile Mass: 0.5`,
`After add, leaderstats Mass: 0.5`. Confirm via `get_console_output`.

Stop Play mode afterward (`start_stop_play`) so the next task starts from a clean server.

- [ ] **Step 3: Commit**

```bash
git add src/ServerScriptService/Services/PlayerDataService.lua
git commit -m "Implement PlayerDataService in-memory profile cache and leaderstats"
```

---

### Task 3: `EconomyService.lua` — sole owner of Coin/Mass grants

**Files:**
- Modify: `src/ServerScriptService/Services/EconomyService.lua`

**Interfaces:**
- Consumes: `PlayerDataService.AddCoins(player, amount)`, `PlayerDataService.AddMass(player, amount)`
  (Task 2); `ZoneConfig[zoneId]` table with `.CoinsPerBite`/`.MassPerBite` fields
  (`src/ReplicatedStorage/Modules/Config/ZoneConfig.lua`, already exists).
- Produces: `EconomyService.Start()`, `EconomyService.GrantEatReward(player: Player, zoneId: number)`.
  `FoodService` (Task 4) calls `GrantEatReward`; nothing else may call it or touch currency.

- [ ] **Step 1: Implement the service**

Replace the full contents of `src/ServerScriptService/Services/EconomyService.lua` with:
```lua
-- EconomyService.lua
-- Sole owner of Coin/Mass grants. No other script mutates these values directly.
-- All grants must be server-triggered and validated against ZoneConfig — never trust
-- a client-sent currency amount.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZoneConfig = require(ReplicatedStorage.Modules.Config.ZoneConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)

local EconomyService = {}

function EconomyService.GrantEatReward(player, zoneId)
	local zone = ZoneConfig[zoneId]
	if not zone then
		return
	end

	PlayerDataService.AddCoins(player, zone.CoinsPerBite)
	PlayerDataService.AddMass(player, zone.MassPerBite)
end

function EconomyService.Start() end

return EconomyService
```

- [ ] **Step 2: Verify in a live Play session**

Start Play mode if needed, then run via `execute_luau`:
```lua
local Players = game:GetService("Players")
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)
local EconomyService = require(game.ServerScriptService.Services.EconomyService)

PlayerDataService.Start()
EconomyService.Start()

local player = Players:GetPlayers()[1]
assert(player, "No test player in this Play session")

local before = PlayerDataService.Get(player)
print("Before:", before.Coins, before.Mass)

EconomyService.GrantEatReward(player, 1)

local after = PlayerDataService.Get(player)
print("After one Zone 1 eat, Coins:", after.Coins, "(expected 1)")
print("After one Zone 1 eat, Mass:", after.Mass, "(expected 0.1)")

EconomyService.GrantEatReward(player, 999)
print("Invalid zoneId did not error, Coins unchanged:", PlayerDataService.Get(player).Coins)
```
Expected output: `Before: 0 0`, `After one Zone 1 eat, Coins: 1 (expected 1)`,
`After one Zone 1 eat, Mass: 0.1 (expected 0.1)`, `Invalid zoneId did not error, Coins unchanged: 1`.
Confirm via `get_console_output`, then stop Play mode.

- [ ] **Step 3: Commit**

```bash
git add src/ServerScriptService/Services/EconomyService.lua
git commit -m "Implement EconomyService eat-reward grants from ZoneConfig"
```

---

### Task 4: `GameplayConfig.lua` + `FoodService.lua` — pickup and eat wiring

**Files:**
- Create: `src/ReplicatedStorage/Modules/Config/GameplayConfig.lua`
- Create: `src/ServerScriptService/Services/FoodService.lua`

**Interfaces:**
- Consumes: `EconomyService.GrantEatReward(player, zoneId)` (Task 3); `ZoneConfig[zoneId].FoodTheme[1]`
  (existing) to resolve the Tool template name; `ReplicatedStorage.Assets.FoodTools.<name>` and
  `Workspace.FoodTables.*` (Task 1). Both read a `ZoneId` attribute at runtime — that attribute isn't
  set until Task 5's `Init.server.lua` boot script runs (see the plan header's Amendment note), so this
  task's own verification (Step 3) sets it manually first as a test fixture, matching how this task's
  verification already manually starts the other services instead of relying on `Init.server.lua`.
- Produces: `FoodService.Start()`, `FoodService.GivePlayerFood(player: Player, zoneId: number)`,
  `FoodService.HandleEatAttempt(player: Player, tool: Tool)`. `Init.server.lua` (Task 5) calls
  `Start()`; the two other functions are exposed specifically so Play-mode verification (this task and
  Task 5) can call them directly without needing a real physical `ProximityPrompt`/`Tool.Activated`
  trigger, since neither of those signals can be fired synthetically from a script.

- [ ] **Step 1: Create the gameplay config**

`src/ReplicatedStorage/Modules/Config/GameplayConfig.lua`:
```lua
-- GameplayConfig.lua
-- Non-zone-specific gameplay tunables. Never hardcode these values in logic scripts.

return {
	EAT_COOLDOWN_SEC = 1, -- placeholder until a real eat animation exists; retune to match its length
}
```

- [ ] **Step 2: Implement FoodService**

`src/ServerScriptService/Services/FoodService.lua`:
```lua
-- FoodService.lua
-- Owns food pickup (ProximityPrompt) and eat (Tool.Activated) wiring.
-- Both signals fire server-side natively — no custom RemoteEvents needed here.
-- Currency math is never done in this file; it always delegates to EconomyService.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZoneConfig = require(ReplicatedStorage.Modules.Config.ZoneConfig)
local GameplayConfig = require(ReplicatedStorage.Modules.Config.GameplayConfig)
local EconomyService = require(script.Parent.EconomyService)

local FoodService = {}

local lastEatTime = {}

local function getFoodToolTemplate(zoneId)
	local zone = ZoneConfig[zoneId]
	if not zone then
		return nil
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local toolsFolder = assets and assets:FindFirstChild("FoodTools")
	if not toolsFolder then
		return nil
	end

	return toolsFolder:FindFirstChild(zone.FoodTheme[1])
end

local function removeExistingFoodTool(player)
	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		for _, item in backpack:GetChildren() do
			if item:IsA("Tool") and item:GetAttribute("ZoneId") ~= nil then
				item:Destroy()
			end
		end
	end

	local character = player.Character
	if character then
		for _, item in character:GetChildren() do
			if item:IsA("Tool") and item:GetAttribute("ZoneId") ~= nil then
				item:Destroy()
			end
		end
	end
end

function FoodService.HandleEatAttempt(player, tool)
	local zoneId = tool:GetAttribute("ZoneId")
	if not zoneId then
		return
	end

	local now = os.clock()
	local last = lastEatTime[player.UserId]
	if last and now - last < GameplayConfig.EAT_COOLDOWN_SEC then
		return
	end
	lastEatTime[player.UserId] = now

	EconomyService.GrantEatReward(player, zoneId)
end

function FoodService.GivePlayerFood(player, zoneId)
	local template = getFoodToolTemplate(zoneId)
	if not template then
		return
	end

	local backpack = player:FindFirstChild("Backpack")
	if not backpack then
		return
	end

	removeExistingFoodTool(player)

	local tool = template:Clone()
	tool.Parent = backpack

	tool.Activated:Connect(function()
		FoodService.HandleEatAttempt(player, tool)
	end)
end

local function onPromptTriggered(prompt, player)
	local tableInstance = prompt.Parent
	if not tableInstance then
		return
	end

	local zoneId = tableInstance:GetAttribute("ZoneId")
	if not zoneId then
		return
	end

	FoodService.GivePlayerFood(player, zoneId)
end

local function onPlayerRemoving(player)
	lastEatTime[player.UserId] = nil
end

function FoodService.Start()
	ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return FoodService
```

- [ ] **Step 3: Verify pickup, replace, and cooldown logic in a live Play session**

Start Play mode if needed, then run via `execute_luau`:
```lua
local Players = game:GetService("Players")
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)
local EconomyService = require(game.ServerScriptService.Services.EconomyService)
local FoodService = require(game.ServerScriptService.Services.FoodService)

PlayerDataService.Start()
EconomyService.Start()
FoodService.Start()

-- Test fixture: Init.server.lua (Task 5) is what sets this permanently at real boot.
-- Set it manually here since this task verifies FoodService in isolation, before Task 5 exists.
workspace.FoodTables.Zone1Table:SetAttribute("ZoneId", 1)
game.ReplicatedStorage.Assets.FoodTools.Broccoli:SetAttribute("ZoneId", 1)

local player = Players:GetPlayers()[1]
assert(player, "No test player in this Play session")

FoodService.GivePlayerFood(player, 1)
local backpack = player.Backpack
local tool = backpack:FindFirstChild("Broccoli")
print("Tool given:", tool ~= nil)
print("Tool ZoneId:", tool and tool:GetAttribute("ZoneId"))

-- Pick up again: should replace, not duplicate
FoodService.GivePlayerFood(player, 1)
local foodToolCount = 0
for _, item in backpack:GetChildren() do
	if item:GetAttribute("ZoneId") ~= nil then
		foodToolCount += 1
	end
end
print("Food tool count after re-pickup (expected 1):", foodToolCount)

local toolAfter = backpack:FindFirstChild("Broccoli")
local coinsBefore = PlayerDataService.Get(player).Coins

FoodService.HandleEatAttempt(player, toolAfter)
print("Coins after 1st eat:", PlayerDataService.Get(player).Coins, "(expected", coinsBefore + 1, ")")

FoodService.HandleEatAttempt(player, toolAfter)
print("Coins after immediate 2nd eat (should be blocked by cooldown):", PlayerDataService.Get(player).Coins, "(expected still", coinsBefore + 1, ")")

task.wait(1.1)
FoodService.HandleEatAttempt(player, toolAfter)
print("Coins after eat past cooldown:", PlayerDataService.Get(player).Coins, "(expected", coinsBefore + 2, ")")
```
Expected output: `Tool given: true`, `Tool ZoneId: 1`, `Food tool count after re-pickup (expected 1): 1`,
`Coins after 1st eat: 1 (expected 1)`, `Coins after immediate 2nd eat (should be blocked by cooldown):
1 (expected still 1)`, `Coins after eat past cooldown: 2 (expected 2)`. Confirm via
`get_console_output`, then stop Play mode.

- [ ] **Step 4: Commit**

```bash
git add src/ReplicatedStorage/Modules/Config/GameplayConfig.lua src/ServerScriptService/Services/FoodService.lua
git commit -m "Implement FoodService pickup/eat wiring with per-player cooldown"
```

---

### Task 5: `Init.server.lua` boot script + full physical end-to-end verification

**Files:**
- Create: `src/ServerScriptService/Init.server.lua`

**Interfaces:**
- Consumes: `PlayerDataService.Start()`, `EconomyService.Start()`, `FoodService.Start()` (Tasks 2–4);
  `Workspace.FoodTables.Zone1Table` and `ReplicatedStorage.Assets.FoodTools.Broccoli` (Task 1, both
  exist but neither has `ZoneId` set yet — see the plan header's Amendment note).
- Produces: nothing further consumed by other tasks — this is the integration point. Runs
  automatically on server boot since it's a `Script` (not a `ModuleScript`) directly under
  `ServerScriptService`. Also produces the actual `ZoneId = 1` attribute assignment on both instances
  above — this is the permanent, real version of the manual `SetAttribute` calls Task 4's own
  verification used as a temporary test fixture.

- [ ] **Step 1: Implement the boot script**

`src/ServerScriptService/Init.server.lua`:
```lua
-- Init.server.lua
-- Boot sequence: requires and starts every Service, in dependency order.
-- Also assigns ZoneId attributes to placeholder world objects programmatically, since Rojo's
-- .model.json format does not apply Attributes from the JSON file in this project's environment
-- (confirmed during Task 1 — see the design spec's Amendment section for full detail).

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Services = ServerScriptService.Services

local PlayerDataService = require(Services.PlayerDataService)
local EconomyService = require(Services.EconomyService)
local FoodService = require(Services.FoodService)

local function assignZoneAttributes()
	workspace.FoodTables.Zone1Table:SetAttribute("ZoneId", 1)
	ReplicatedStorage.Assets.FoodTools.Broccoli:SetAttribute("ZoneId", 1)
end

assignZoneAttributes()

PlayerDataService.Start()
EconomyService.Start()
FoodService.Start()
```

- [ ] **Step 2: Confirm it runs without error and attributes are set on server start**

Start Play mode via the Roblox Studio MCP `start_stop_play` tool, then check
`get_console_output` for any red error text mentioning `Init` or any of the three Services. There
should be none. Then run via `execute_luau` to confirm the attribute assignment actually happened:
```lua
print("Table ZoneId:", workspace.FoodTables.Zone1Table:GetAttribute("ZoneId"), "(expected 1)")
print("Tool ZoneId:", game.ReplicatedStorage.Assets.FoodTools.Broccoli:GetAttribute("ZoneId"), "(expected 1)")
```
Expected: both print `1`.

- [ ] **Step 3: Full physical end-to-end verification (this is the spec's real acceptance test)**

With Play mode still running:
1. Use the Studio MCP character-navigation tool to walk the test character to
   `workspace.FoodTables.Zone1Table` (use its `Position`, e.g. `[10, 2.5, 10]` from Task 1, and stand
   within the `ProximityPrompt`'s `MaxActivationDistance` of 10 studs).
2. Use the MCP keyboard input tool to press `E` (the default `ProximityPrompt` trigger key) to trigger
   the pickup prompt.
3. Run via `execute_luau`:
   ```lua
   local player = game.Players:GetPlayers()[1]
   print("Backpack has Broccoli:", player.Backpack:FindFirstChild("Broccoli") ~= nil)
   ```
   Expected: `Backpack has Broccoli: true`.
4. Use the MCP keyboard input tool to press `1` to equip the hotbar slot.
5. Run via `execute_luau` to confirm equip:
   ```lua
   local player = game.Players:GetPlayers()[1]
   print("Broccoli equipped in Character:", player.Character:FindFirstChild("Broccoli") ~= nil)
   ```
   Expected: `Broccoli equipped in Character: true`.
6. Use the MCP mouse input tool to click once while the tool is equipped.
7. Run via `execute_luau`:
   ```lua
   local player = game.Players:GetPlayers()[1]
   local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)
   print("Coins after real click:", PlayerDataService.Get(player).Coins, "(expected 1)")
   print("Mass after real click:", PlayerDataService.Get(player).Mass, "(expected 0.1)")
   print("leaderstats Coins:", player.leaderstats.Coins.Value, "(expected 1)")
   ```
   Expected: `Coins after real click: 1 (expected 1)`, `Mass after real click: 0.1 (expected 0.1)`,
   `leaderstats Coins: 1 (expected 1)`.
8. Check `get_console_output` for any errors throughout steps 1–7.
9. Stop Play mode.

If step 1–2 can't physically trigger the prompt (e.g. navigation/input tooling limitations), fall back
to confirming the `ProximityPromptService.PromptTriggered` wiring by code review of `FoodService.lua`
(already covered by Task 4's direct-call tests) and note in your task report which physical steps
could not be exercised and why — do not claim the physical path was verified if it wasn't actually
driven end-to-end.

- [ ] **Step 4: Commit**

```bash
git add src/ServerScriptService/Init.server.lua
git commit -m "Wire up service boot sequence in Init.server.lua"
```

---

### Task 6: Update this project's `CLAUDE.md` to reflect the new structure

**Files:**
- Modify: `CLAUDE.md` (the "Roblox Eating Game" one, at the repo root)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing — documentation only, but required per this project's own instructions ("this
  file should always reflect the current source of truth").

- [ ] **Step 1: Update the Project Structure section**

Find this block in `CLAUDE.md`:
```
src/
  ServerScriptService/
    Services/
      PlayerDataService.lua   -- owns all DataStore I/O
      EconomyService.lua      -- owns all Coin/Mass grants
      GachaService.lua        -- crate pulls, pity, inventory grants
      RebirthService.lua      -- rebirth eligibility + reset + multiplier
      LeaderboardService.lua  -- OrderedDataStore leaderboard
    RemoteHandlers/            -- server-side listeners for client RemoteEvents
  ReplicatedStorage/
    Modules/
      Config/
        ZoneConfig.lua
        GachaConfig.lua
        RebirthConfig.lua
    Remotes/                   -- RemoteEvent/RemoteFunction instances
  StarterPlayer/
    StarterPlayerScripts/      -- client-side UI/controllers
```

Replace it with:
```
src/
  ServerScriptService/
    Init.server.lua            -- boot sequence, requires + starts every Service
    Services/
      PlayerDataService.lua   -- owns the in-memory PlayerProfile cache + leaderstats (DataStore I/O deferred)
      EconomyService.lua      -- owns all Coin/Mass grants
      FoodService.lua         -- food pickup (ProximityPrompt) + eat (Tool.Activated) wiring
      GachaService.lua        -- crate pulls, pity, inventory grants
      RebirthService.lua      -- rebirth eligibility + reset + multiplier
      LeaderboardService.lua  -- OrderedDataStore leaderboard
    RemoteHandlers/            -- server-side listeners for client RemoteEvents
  ReplicatedStorage/
    Modules/
      Config/
        ZoneConfig.lua
        GachaConfig.lua
        RebirthConfig.lua
        GameplayConfig.lua    -- non-zone-specific tunables (e.g. EAT_COOLDOWN_SEC)
    Assets/
      FoodTools/               -- Tool templates, git-tracked as Rojo .model.json (e.g. Broccoli.model.json)
    Remotes/                   -- RemoteEvent/RemoteFunction instances
  Workspace/
    FoodTables/                -- placeholder food table Parts, git-tracked as Rojo .model.json
  StarterPlayer/
    StarterPlayerScripts/      -- client-side UI/controllers
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md project structure for the food pickup/eat loop"
```

---

## Self-Review Notes

**Spec coverage:** ProximityPrompt pickup (Task 1 + 4), Tool-based hotbar equip (Task 1, built-in
Roblox behavior, verified in Task 5), click-to-eat with cooldown (Task 4), tool replacement not
duplication (Task 4), tool never consumed (Task 4 — `HandleEatAttempt` never destroys `tool`),
EconomyService as sole currency owner (Task 3), PlayerDataService in-memory + leaderstats (Task 2),
git-tracked placeholder assets (Task 1), CLAUDE.md kept current (Task 6). All spec sections have a
corresponding task.

**Placeholder scan:** no TBD/TODO left unresolved except the intentionally-deferred DataStore-flush
comment in `PlayerDataService.lua`, which is explicitly documented as deferred in both the spec and
this plan's Global Constraints, not a gap.

**Type consistency:** `FoodService.GivePlayerFood(player, zoneId)` and
`FoodService.HandleEatAttempt(player, tool)` signatures are identical everywhere they're referenced
(Task 4's own steps and its Interfaces block). `EconomyService.GrantEatReward(player, zoneId)` matches
between Task 3 and Task 4. `PlayerDataService.AddCoins/AddMass(player, amount)` matches between Task 2

**Amendment consistency (added during implementation):** the `ZoneId` attribute mechanism changed from
Rojo `.model.json` `Attributes` (didn't work) to `Instance:SetAttribute` in `Init.server.lua` (Task 5,
confirmed working including surviving `:Clone()`). Task 1's `.model.json` files, Task 1's own
verification, Task 4's verification (temporary manual `SetAttribute` fixture), and Task 5's boot script
and verification were all updated together for this — no task still references the old
`.model.json`-based mechanism as if it worked.
and Task 3.
