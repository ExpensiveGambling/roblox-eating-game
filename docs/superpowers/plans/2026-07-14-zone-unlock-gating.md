# Zone Unlock Gating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Zone 2 a real coin-gated unlock: players pay `ZoneConfig[2].UnlockCost` at a physical
gate to pass through an invisible wall, with per-player enforcement (one player unlocking Zone 2 must
not open it for anyone else in the same server), plus a server-side fallback check on food pickup in
case the wall is ever bypassed.

**Architecture:** A new `ZoneAccessService.lua` owns a per-player `CollisionGroup`
(`Player_<UserId>`) and a per-zone `CollisionGroup` (`ZoneWall_<zoneId>`), and uses
`PhysicsService:CollisionGroupSetCollidable` to make the same physical wall solid for one player and
passable for another. `PlayerDataService` gains `SpendCoins`/`UnlockZone`, mirroring its existing
`AddCoins`/`AddMass` style. `FoodService` gains a `CanEatFromZone` guard as defense-in-depth, plus a
folder-scoping fix (see Task 2) needed to stop it from misfiring on the new gate's prompt. Zone 2 gets
one physical gate (four wall `Part`s forming a box, one carrying the unlock `ProximityPrompt`) and one
table/food pair (Sandwich), built now to prove the pattern end-to-end — Zones 3-5 are deferred.

**Tech Stack:** Luau (Roblox), `PhysicsService` (built-in `CollisionGroup` API), native
`ProximityPromptService.PromptTriggered` (no `RemoteEvent`s — matches this project's existing
food-pickup pattern, not the unrelated Spotlight project's `RemoteNames.lua` convention), Roblox Studio
MCP connection for live verification.

**No automated test framework exists in this repo** (no TestEZ, no CI), consistent with prior plans.
Every task's "test" step is: write the code, then exercise it live via the Roblox Studio MCP
`execute_luau` tool (and, for Task 6, `character_navigation`/`user_keyboard_input` for real physical
movement) against a running Play-mode session, confirming output via `get_console_output`.

## Global Constraints

- Server-authoritative: nothing about a purchase (cost, success, `UnlockedZones` membership) is ever
  decided or trusted from the client — this feature uses zero `RemoteEvent`s, only native
  server-side-firing `ProximityPromptService.PromptTriggered` (per `CLAUDE.md`'s non-negotiable rules).
- Fail-closed: every guard in the unlock purchase flow is a silent no-op on failure — no client-facing
  error message, per explicit user decision during brainstorming (see the design spec).
- Sequential unlock is enforced: zone `N` cannot be unlocked unless zone `N-1` is already in
  `UnlockedZones` (per `CLAUDE.md`'s gamepass note: "VIP zone early access... not zone-skip exploits").
- Rojo's `.model.json` format does **not** apply `Attributes` from the JSON file in this project's
  environment (confirmed in the food-pickup-eat-loop design spec's Amendment section, and recorded in
  this project's `feedback_rojo_environment_gotchas` memory). `ZoneId` attributes continue to be set
  **programmatically** via `SetAttribute` in `Init.server.lua`, exactly like the existing
  `Zone1Table`/`Broccoli` pattern. For the same reason (avoid depending on unclear Rojo→live-property
  sync behavior for anything non-trivial), `BasePart.CollisionGroup` is also set **programmatically**
  in `ZoneAccessService.lua`, never authored in a `.model.json` file — the group must be registered via
  `PhysicsService:RegisterCollisionGroup` before a `CollisionGroup` assignment to it is meaningful
  anyway, which a static JSON property can't sequence correctly.
- No script outside `PlayerDataService` touches the profile `Cache` directly (unchanged repo-wide rule)
  — `UnlockedZones` mutation goes through the new `PlayerDataService.UnlockZone`, not direct table
  access from `ZoneAccessService`.
- PascalCase for scripts/modules, camelCase for variables/functions, ALL_CAPS for constants (per
  `CLAUDE.md`).

**Design spec:** `docs/superpowers/specs/2026-07-14-zone-unlock-gating-design.md` — read this first for
full rationale, including why `CollisionGroup`s (not a teleport-back trigger) was the chosen mechanism
and the full list of deferred scope (multi-food-per-zone, Zones 3-5, custom purchase-failure UI, VIP
gamepass).

---

### Task 1: `PlayerDataService.lua` — `SpendCoins` and `UnlockZone`

**Files:**
- Modify: `src/ServerScriptService/Services/PlayerDataService.lua`

**Interfaces:**
- Consumes: existing internal `Cache` table (no new external dependency).
- Produces: `PlayerDataService.SpendCoins(player, amount): boolean` (atomic check-and-deduct, returns
  whether it succeeded), `PlayerDataService.UnlockZone(player, zoneId)` (appends `zoneId` to
  `profile.UnlockedZones` if not already present; no-op if the profile isn't cached). Both used by
  `ZoneAccessService` in Task 5.

- [ ] **Step 1: Add `SpendCoins` and `UnlockZone` right after `AddMass`**

In `src/ServerScriptService/Services/PlayerDataService.lua`, find the existing `AddMass` function:
```lua
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
```
Add these two functions immediately after it (before `function PlayerDataService.Start()`):
```lua
function PlayerDataService.SpendCoins(player, amount)
	local profile = Cache[player.UserId]
	if not profile or profile.Coins < amount then
		return false
	end
	profile.Coins -= amount
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		leaderstats.Coins.Value = profile.Coins
	end
	return true
end

function PlayerDataService.UnlockZone(player, zoneId)
	local profile = Cache[player.UserId]
	if not profile then
		return
	end
	if table.find(profile.UnlockedZones, zoneId) then
		return
	end
	table.insert(profile.UnlockedZones, zoneId)
end
```

- [ ] **Step 2: Verify via MCP against a running Play session**

Start Play mode via `start_stop_play`, then run via `execute_luau`:
```lua
local Players = game:GetService("Players")
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)

local player = Players:GetPlayers()[1]
assert(player, "No test player in this Play session")

local profile = PlayerDataService.Get(player)
profile.Coins = 100

print("SpendCoins(50) with 100 available:", PlayerDataService.SpendCoins(player, 50), "(expected true)")
print("Coins after spend:", profile.Coins, "(expected 50)")
print("SpendCoins(999) with 50 available:", PlayerDataService.SpendCoins(player, 999), "(expected false)")
print("Coins unchanged after failed spend:", profile.Coins, "(expected 50)")

print("UnlockedZones before:", table.concat(profile.UnlockedZones, ","), "(expected 1)")
PlayerDataService.UnlockZone(player, 2)
print("UnlockedZones after UnlockZone(2):", table.concat(profile.UnlockedZones, ","), "(expected 1,2)")
PlayerDataService.UnlockZone(player, 2)
print("UnlockedZones after duplicate UnlockZone(2):", table.concat(profile.UnlockedZones, ","), "(expected 1,2, no duplicate)")
```
Expected output, in order: `SpendCoins(50) with 100 available: true`, `Coins after spend: 50`,
`SpendCoins(999) with 50 available: false`, `Coins unchanged after failed spend: 50`,
`UnlockedZones before: 1`, `UnlockedZones after UnlockZone(2): 1,2`, `UnlockedZones after duplicate
UnlockZone(2): 1,2, no duplicate`. Confirm via `get_console_output`, no warnings.

- [ ] **Step 3: Commit**

```bash
git add src/ServerScriptService/Services/PlayerDataService.lua
git commit -m "Add SpendCoins and UnlockZone to PlayerDataService"
```

---

### Task 2: `FoodService.lua` — folder-scoped prompt handling + `CanEatFromZone` guard

**Files:**
- Modify: `src/ServerScriptService/Services/FoodService.lua`

**Interfaces:**
- Consumes: `PlayerDataService.Get(player) -> PlayerProfile` (existing).
- Produces: `FoodService.CanEatFromZone(player, zoneId): boolean` (new export, exposed specifically so
  it can be unit-tested without a real physical `ProximityPrompt` interaction — Roblox does not expose
  a way to programmatically fire `ProximityPromptService.PromptTriggered`).

This task fixes a real cross-talk bug that Task 3's new assets would otherwise introduce: today,
`FoodService.onPromptTriggered` treats *any* `ProximityPrompt` whose parent has a `ZoneId` attribute as
a food pickup. Task 3 adds a `ZoneId`-tagged wall `Part` with its own `ProximityPrompt` (the unlock
gate) under `Workspace.ZoneGates` — without this fix, holding that gate's prompt would also silently
hand the player a Sandwich tool. The fix scopes `FoodService` to only react to prompts whose parent is
under `Workspace.FoodTables`.

- [ ] **Step 1: Add a `require` for `PlayerDataService`**

In `src/ServerScriptService/Services/FoodService.lua`, find:
```lua
local ZoneConfig = require(ReplicatedStorage.Modules.Config.ZoneConfig)
local GameplayConfig = require(ReplicatedStorage.Modules.Config.GameplayConfig)
local EconomyService = require(script.Parent.EconomyService)
```
Replace with:
```lua
local ZoneConfig = require(ReplicatedStorage.Modules.Config.ZoneConfig)
local GameplayConfig = require(ReplicatedStorage.Modules.Config.GameplayConfig)
local EconomyService = require(script.Parent.EconomyService)
local PlayerDataService = require(script.Parent.PlayerDataService)
```

- [ ] **Step 2: Add `CanEatFromZone` and fix `onPromptTriggered`**

Find:
```lua
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
```
Replace with:
```lua
function FoodService.CanEatFromZone(player, zoneId)
	local profile = PlayerDataService.Get(player)
	if not profile then
		return false
	end
	return table.find(profile.UnlockedZones, zoneId) ~= nil
end

local function onPromptTriggered(prompt, player)
	local tableInstance = prompt.Parent
	if not tableInstance then
		return
	end

	local foodTables = workspace:FindFirstChild("FoodTables")
	if not foodTables or not tableInstance:IsDescendantOf(foodTables) then
		return
	end

	local zoneId = tableInstance:GetAttribute("ZoneId")
	if not zoneId then
		return
	end

	if not FoodService.CanEatFromZone(player, zoneId) then
		return
	end

	FoodService.GivePlayerFood(player, zoneId)
end
```
(`FoodService.CanEatFromZone` must be defined before `onPromptTriggered` since the local function
references it — placing it directly above, as shown, satisfies that.)

- [ ] **Step 3: Verify via MCP**

With Play mode running (reuse the session from Task 1, or start a fresh one), run via `execute_luau`:
```lua
local Players = game:GetService("Players")
local FoodService = require(game.ServerScriptService.Services.FoodService)
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)

local player = Players:GetPlayers()[1]
assert(player, "No test player in this Play session")

local profile = PlayerDataService.Get(player)
profile.UnlockedZones = { 1 }

print("CanEatFromZone(1) with only zone 1 unlocked:", FoodService.CanEatFromZone(player, 1), "(expected true)")
print("CanEatFromZone(2) with only zone 1 unlocked:", FoodService.CanEatFromZone(player, 2), "(expected false)")

PlayerDataService.UnlockZone(player, 2)
print("CanEatFromZone(2) after unlocking zone 2:", FoodService.CanEatFromZone(player, 2), "(expected true)")
```
Expected output: `CanEatFromZone(1) with only zone 1 unlocked: true`, `CanEatFromZone(2) with only zone
1 unlocked: false`, `CanEatFromZone(2) after unlocking zone 2: true`. Confirm via `get_console_output`.

Also confirm the existing Zone 1 pickup flow still works unmodified: walk to the Zone 1 table in the
live Play session and pick up/eat Broccoli as before (this exercises the new
`tableInstance:IsDescendantOf(foodTables)` check against a real table for the first time — Zone 1 must
still work exactly as it did before this task).

- [ ] **Step 4: Commit**

```bash
git add src/ServerScriptService/Services/FoodService.lua
git commit -m "Scope FoodService prompts to FoodTables and add CanEatFromZone guard"
```

---

### Task 3: Zone 2 Workspace/ReplicatedStorage assets

**Files:**
- Create: `src/Workspace/FoodTables/Zone2Table.model.json`
- Create: `src/ReplicatedStorage/Assets/FoodTools/Sandwich.model.json`
- Create: `src/Workspace/ZoneGates/Zone2Gate.model.json`
- Modify: `src/ServerScriptService/Init.server.lua`

**Interfaces:**
- Consumes: nothing (pure asset + attribute-wiring task).
- Produces: `workspace.FoodTables.Zone2Table` (tagged `ZoneId = 2`),
  `ReplicatedStorage.Assets.FoodTools.Sandwich` (tagged `ZoneId = 2`),
  `workspace.ZoneGates.Zone2Gate` (a `Model` with four wall `Part` children — `GateWall`, `NorthWall`,
  `EastWall`, `WestWall` — each tagged `ZoneId = 2`; `GateWall` has an `UnlockPrompt`
  `ProximityPrompt` child). These are what Task 4's `ZoneAccessService` scans for and Task 5's purchase
  handler reacts to.

Placeholder `CFrame`/`Size` values below are hand-picked reasonable defaults (not visually tuned in the
Studio viewport), following this project's existing convention for the Zone 1 table. The gate box
surrounds a 20x22-stud area centered at `(10, _, 40)` — a clean 30-stud gap north of the Zone 1 table
at `(10, 2.5, 10)`. Wall parts sit on the ground plane (`Baseplate` top surface is at `y = 2`, same
reference the existing `Zone1Table` uses) with a 12-stud height.

- [ ] **Step 1: Create `Zone2Table.model.json`**

`src/Workspace/FoodTables/Zone2Table.model.json`:
```json
{
  "Name": "Zone2Table",
  "ClassName": "Part",
  "Properties": {
    "Size": { "Vector3": [4, 1, 4] },
    "Position": { "Vector3": [10, 2.5, 40] },
    "Anchored": true,
    "CanCollide": true,
    "Color": { "Color3": [0.6, 0.4, 0.2] }
  },
  "Children": [
    {
      "Name": "PickupPrompt",
      "ClassName": "ProximityPrompt",
      "Properties": {
        "ActionText": "Pick Up",
        "ObjectText": "Sandwich",
        "MaxActivationDistance": 10
      }
    }
  ]
}
```

- [ ] **Step 2: Create `Sandwich.model.json`**

`src/ReplicatedStorage/Assets/FoodTools/Sandwich.model.json`:
```json
{
  "Name": "Sandwich",
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
        "Color": { "Color3": [0.87, 0.72, 0.53] }
      }
    }
  ]
}
```

- [ ] **Step 3: Create `Zone2Gate.model.json`**

`src/Workspace/ZoneGates/Zone2Gate.model.json`:
```json
{
  "Name": "Zone2Gate",
  "ClassName": "Model",
  "Children": [
    {
      "Name": "GateWall",
      "ClassName": "Part",
      "Properties": {
        "Size": { "Vector3": [22, 12, 1] },
        "Position": { "Vector3": [10, 8, 30] },
        "Anchored": true,
        "CanCollide": true,
        "Transparency": 0.7,
        "Color": { "Color3": [0.8, 0.2, 0.2] }
      },
      "Children": [
        {
          "Name": "UnlockPrompt",
          "ClassName": "ProximityPrompt",
          "Properties": {
            "ActionText": "Unlock",
            "ObjectText": "Kitchen",
            "MaxActivationDistance": 10
          }
        }
      ]
    },
    {
      "Name": "NorthWall",
      "ClassName": "Part",
      "Properties": {
        "Size": { "Vector3": [22, 12, 1] },
        "Position": { "Vector3": [10, 8, 50] },
        "Anchored": true,
        "CanCollide": true,
        "Transparency": 0.7,
        "Color": { "Color3": [0.8, 0.2, 0.2] }
      }
    },
    {
      "Name": "EastWall",
      "ClassName": "Part",
      "Properties": {
        "Size": { "Vector3": [1, 12, 22] },
        "Position": { "Vector3": [21, 8, 40] },
        "Anchored": true,
        "CanCollide": true,
        "Transparency": 0.7,
        "Color": { "Color3": [0.8, 0.2, 0.2] }
      }
    },
    {
      "Name": "WestWall",
      "ClassName": "Part",
      "Properties": {
        "Size": { "Vector3": [1, 12, 22] },
        "Position": { "Vector3": [-1, 8, 40] },
        "Anchored": true,
        "CanCollide": true,
        "Transparency": 0.7,
        "Color": { "Color3": [0.8, 0.2, 0.2] }
      }
    }
  ]
}
```
(`ObjectText`/`ActionText` here are just JSON-required defaults — Task 5's `ZoneAccessService` will
overwrite them at server boot from `ZoneConfig[2].Name`/`UnlockCost`, so this file never needs manual
edits when balancing numbers change.)

- [ ] **Step 4: Extend `Init.server.lua`'s `assignZoneAttributes`**

In `src/ServerScriptService/Init.server.lua`, find:
```lua
local function assignZoneAttributes()
	workspace.FoodTables.Zone1Table:SetAttribute("ZoneId", 1)
	ReplicatedStorage.Assets.FoodTools.Broccoli:SetAttribute("ZoneId", 1)
end
```
Replace with:
```lua
local function assignZoneAttributes()
	workspace.FoodTables.Zone1Table:SetAttribute("ZoneId", 1)
	ReplicatedStorage.Assets.FoodTools.Broccoli:SetAttribute("ZoneId", 1)

	workspace.FoodTables.Zone2Table:SetAttribute("ZoneId", 2)
	ReplicatedStorage.Assets.FoodTools.Sandwich:SetAttribute("ZoneId", 2)

	for _, wall in workspace.ZoneGates.Zone2Gate:GetChildren() do
		if wall:IsA("BasePart") then
			wall:SetAttribute("ZoneId", 2)
		end
	end
end
```

- [ ] **Step 5: Verify via MCP**

Start (or restart) Play mode so Rojo syncs the new files, then run via `execute_luau`:
```lua
local zone2Table = workspace.FoodTables:FindFirstChild("Zone2Table")
local sandwich = game.ReplicatedStorage.Assets.FoodTools:FindFirstChild("Sandwich")
local gate = workspace.ZoneGates:FindFirstChild("Zone2Gate")

print("Zone2Table exists:", zone2Table ~= nil, "(expected true)")
print("Zone2Table ZoneId:", zone2Table and zone2Table:GetAttribute("ZoneId"), "(expected 2)")
print("Sandwich exists:", sandwich ~= nil, "(expected true)")
print("Sandwich ZoneId:", sandwich and sandwich:GetAttribute("ZoneId"), "(expected 2)")
print("Zone2Gate exists:", gate ~= nil, "(expected true)")

if gate then
	for _, wall in gate:GetChildren() do
		print(("Wall %s ZoneId: %s (expected 2)"):format(wall.Name, tostring(wall:GetAttribute("ZoneId"))))
	end
	print("GateWall has UnlockPrompt:", gate.GateWall:FindFirstChild("UnlockPrompt") ~= nil, "(expected true)")
end
```
Expected output: all four `exists` checks `true`, both `ZoneId` prints `2`, all four wall
`ZoneId` prints `2`, and `GateWall has UnlockPrompt: true`. Confirm via `get_console_output`.

- [ ] **Step 6: Commit**

```bash
git add src/Workspace/FoodTables/Zone2Table.model.json src/ReplicatedStorage/Assets/FoodTools/Sandwich.model.json src/Workspace/ZoneGates/Zone2Gate.model.json src/ServerScriptService/Init.server.lua
git commit -m "Add Zone 2 table, food tool, and unlock-gate placeholder assets"
```

---

### Task 4: `ZoneAccessService.lua` — CollisionGroup infrastructure

**Files:**
- Create: `src/ServerScriptService/Services/ZoneAccessService.lua`
- Modify: `src/ServerScriptService/Init.server.lua`

**Interfaces:**
- Consumes: `PlayerDataService.Get(player) -> PlayerProfile` (Task 1's existing accessor),
  `workspace.ZoneGates` (Task 3).
- Produces (module-internal, used by Task 5 in the same file): `zoneWallGroups` table (`zoneId ->
  CollisionGroup name`), `playerGroupName(player): string`. `ZoneAccessService.Start()` is the only
  function called from outside this file in this task.

This task only builds the wall-blocking mechanism (every player bounces off Zone 2's wall by default,
since `UnlockedZones` starts as `{1}`). Task 5 adds the purchase flow that lets a player open it.

- [ ] **Step 1: Create `ZoneAccessService.lua`**

`src/ServerScriptService/Services/ZoneAccessService.lua`:
```lua
-- ZoneAccessService.lua
-- Owns per-player CollisionGroup wiring for zone-unlock walls. No other script registers
-- CollisionGroups or reads Workspace.ZoneGates.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerDataService = require(script.Parent.PlayerDataService)

local ZoneAccessService = {}

local WALL_GROUP_PREFIX = "ZoneWall_"
local PLAYER_GROUP_PREFIX = "Player_"

-- zoneId -> CollisionGroup name, populated by scanning Workspace.ZoneGates in Start().
local zoneWallGroups = {}

local function playerGroupName(player)
	return PLAYER_GROUP_PREFIX .. tostring(player.UserId)
end

local function wallGroupName(zoneId)
	return WALL_GROUP_PREFIX .. tostring(zoneId)
end

-- Scans Workspace.ZoneGates for BaseParts tagged with a ZoneId attribute, registers one
-- CollisionGroup per distinct ZoneId found, and assigns each wall Part to its group.
local function setUpZoneWallGroups()
	local zoneGates = workspace:FindFirstChild("ZoneGates")
	if not zoneGates then
		return
	end

	for _, wall in zoneGates:GetDescendants() do
		if wall:IsA("BasePart") then
			local zoneId = wall:GetAttribute("ZoneId")
			if zoneId then
				local groupName = wallGroupName(zoneId)
				if not zoneWallGroups[zoneId] then
					zoneWallGroups[zoneId] = groupName
					PhysicsService:RegisterCollisionGroup(groupName)
				end
				wall.CollisionGroup = groupName
			end
		end
	end
end

-- Sets this player's CollisionGroup collidability against every known zone wall group to match
-- their current UnlockedZones. Called on spawn/respawn.
local function syncPlayerCollision(player)
	local profile = PlayerDataService.Get(player)
	if not profile then
		return
	end

	local groupName = playerGroupName(player)
	for zoneId, wallGroup in zoneWallGroups do
		local unlocked = table.find(profile.UnlockedZones, zoneId) ~= nil
		PhysicsService:CollisionGroupSetCollidable(groupName, wallGroup, not unlocked)
	end
end

local function assignCharacterCollisionGroup(player, character)
	local groupName = playerGroupName(player)

	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = groupName
		end
	end

	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = groupName
		end
	end)
end

local function onCharacterAdded(player, character)
	assignCharacterCollisionGroup(player, character)
	syncPlayerCollision(player)
end

local function onPlayerAdded(player)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(playerGroupName(player))
	end)

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

local function onPlayerRemoving(player)
	pcall(function()
		PhysicsService:UnregisterCollisionGroup(playerGroupName(player))
	end)
end

function ZoneAccessService.Start()
	setUpZoneWallGroups()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return ZoneAccessService
```

(This file intentionally does not yet reference `ZoneConfig` or `ProximityPromptService` — Task 5 adds
both, plus the `TryUnlockZone` function, `zoneWallGroups` and `playerGroupName` above are written now
so Task 5 can use them without restructuring this file.)

- [ ] **Step 2: Wire into `Init.server.lua`**

Find:
```lua
local PlayerDataService = require(Services.PlayerDataService)
local EconomyService = require(Services.EconomyService)
local FoodService = require(Services.FoodService)
```
Replace with:
```lua
local PlayerDataService = require(Services.PlayerDataService)
local ZoneAccessService = require(Services.ZoneAccessService)
local EconomyService = require(Services.EconomyService)
local FoodService = require(Services.FoodService)
```
Find:
```lua
PlayerDataService.Start()
EconomyService.Start()
FoodService.Start()
```
Replace with:
```lua
PlayerDataService.Start()
ZoneAccessService.Start()
EconomyService.Start()
FoodService.Start()
```

- [ ] **Step 3: Verify via MCP**

Restart Play mode (so `Init.server.lua` reruns with the new `ZoneAccessService.Start()` call), then run
via `execute_luau`:
```lua
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)

local player = Players:GetPlayers()[1]
assert(player, "No test player in this Play session")

print("ZoneWall_2 registered:", PhysicsService:IsCollisionGroupRegistered("ZoneWall_2"), "(expected true)")

local playerGroup = "Player_" .. tostring(player.UserId)
print("Player group registered:", PhysicsService:IsCollisionGroupRegistered(playerGroup), "(expected true)")

local profile = PlayerDataService.Get(player)
print("Fresh player UnlockedZones:", table.concat(profile.UnlockedZones, ","), "(expected 1)")
print(
	"ZoneWall_2 collidable against fresh player (should be solid/true):",
	PhysicsService:CollisionGroupsAreCollidable(playerGroup, "ZoneWall_2"),
	"(expected true)"
)

for _, wall in workspace.ZoneGates.Zone2Gate:GetChildren() do
	print(("%s CollisionGroup: %s (expected ZoneWall_2)"):format(wall.Name, wall.CollisionGroup))
end
```
Expected output: `ZoneWall_2 registered: true`, `Player group registered: true`, `Fresh player
UnlockedZones: 1`, `ZoneWall_2 collidable against fresh player (should be solid/true): true`, and all
four walls print `CollisionGroup: ZoneWall_2`. Confirm via `get_console_output`.

Also physically confirm in the live Play session: walk the test character toward the Zone 2 gate
(north of the Zone 1 table) and confirm you bounce off the wall — this is the first real proof the
CollisionGroup wiring works end-to-end, not just in isolation.

- [ ] **Step 4: Commit**

```bash
git add src/ServerScriptService/Services/ZoneAccessService.lua src/ServerScriptService/Init.server.lua
git commit -m "Add ZoneAccessService CollisionGroup infrastructure for zone walls"
```

---

### Task 5: `ZoneAccessService.lua` — unlock-gate purchase handler

**Files:**
- Modify: `src/ServerScriptService/Services/ZoneAccessService.lua`

**Interfaces:**
- Consumes: `PlayerDataService.Get`, `PlayerDataService.SpendCoins`, `PlayerDataService.UnlockZone`
  (Task 1), `ZoneConfig` (existing module), `zoneWallGroups`/`playerGroupName` (Task 4, same file).
- Produces: `ZoneAccessService.TryUnlockZone(player, zoneId): boolean` — exported specifically so it's
  directly testable (same reasoning as `FoodService.CanEatFromZone` in Task 2: Roblox doesn't expose a
  way to programmatically fire a real `ProximityPrompt` trigger). Wired internally to
  `ProximityPromptService.PromptTriggered` for real gate interactions.

- [ ] **Step 1: Add the `ZoneConfig`/`ProximityPromptService` requires**

In `src/ServerScriptService/Services/ZoneAccessService.lua`, find:
```lua
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerDataService = require(script.Parent.PlayerDataService)
```
Replace with:
```lua
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZoneConfig = require(ReplicatedStorage.Modules.Config.ZoneConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)
```

- [ ] **Step 2: Add `TryUnlockZone`, the gate prompt handler, and gate text setup**

Find:
```lua
function ZoneAccessService.Start()
	setUpZoneWallGroups()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return ZoneAccessService
```
Replace with:
```lua
function ZoneAccessService.TryUnlockZone(player, zoneId)
	local zone = ZoneConfig[zoneId]
	if not zone then
		return false
	end

	local profile = PlayerDataService.Get(player)
	if not profile then
		return false
	end

	if table.find(profile.UnlockedZones, zoneId) then
		return false
	end

	if not table.find(profile.UnlockedZones, zoneId - 1) then
		return false
	end

	if not PlayerDataService.SpendCoins(player, zone.UnlockCost) then
		return false
	end

	PlayerDataService.UnlockZone(player, zoneId)

	local wallGroup = zoneWallGroups[zoneId]
	if wallGroup then
		PhysicsService:CollisionGroupSetCollidable(playerGroupName(player), wallGroup, false)
	end

	return true
end

local function onGatePromptTriggered(prompt, player)
	local gate = prompt.Parent
	if not gate then
		return
	end

	local zoneGates = workspace:FindFirstChild("ZoneGates")
	if not zoneGates or not gate:IsDescendantOf(zoneGates) then
		return
	end

	local zoneId = gate:GetAttribute("ZoneId")
	if not zoneId then
		return
	end

	ZoneAccessService.TryUnlockZone(player, zoneId)
end

-- Sets each gate prompt's display text from ZoneConfig, so balancing changes never require
-- re-editing the .model.json placeholder files.
local function setGatePromptText()
	local zoneGates = workspace:FindFirstChild("ZoneGates")
	if not zoneGates then
		return
	end

	for _, prompt in zoneGates:GetDescendants() do
		if prompt:IsA("ProximityPrompt") then
			local gate = prompt.Parent
			local zoneId = gate and gate:GetAttribute("ZoneId")
			local zone = zoneId and ZoneConfig[zoneId]
			if zone then
				prompt.ObjectText = zone.Name
				prompt.ActionText = ("Unlock (%d Coins)"):format(zone.UnlockCost)
			end
		end
	end
end

function ZoneAccessService.Start()
	setUpZoneWallGroups()
	setGatePromptText()

	ProximityPromptService.PromptTriggered:Connect(onGatePromptTriggered)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return ZoneAccessService
```

- [ ] **Step 3: Verify via MCP**

Restart Play mode, then run via `execute_luau`:
```lua
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ZoneAccessService = require(game.ServerScriptService.Services.ZoneAccessService)
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)

local player = Players:GetPlayers()[1]
assert(player, "No test player in this Play session")

local profile = PlayerDataService.Get(player)
profile.Coins = 100
profile.UnlockedZones = { 1 }

print("TryUnlockZone(2) with 100 coins (needs 500):", ZoneAccessService.TryUnlockZone(player, 2), "(expected false)")
print("UnlockedZones unchanged:", table.concat(profile.UnlockedZones, ","), "(expected 1)")

profile.Coins = 600
print("TryUnlockZone(2) with 600 coins:", ZoneAccessService.TryUnlockZone(player, 2), "(expected true)")
print("Coins after unlock:", profile.Coins, "(expected 100)")
print("UnlockedZones after unlock:", table.concat(profile.UnlockedZones, ","), "(expected 1,2)")

local playerGroup = "Player_" .. tostring(player.UserId)
print(
	"ZoneWall_2 collidable after unlock (should be passable/false):",
	PhysicsService:CollisionGroupsAreCollidable(playerGroup, "ZoneWall_2"),
	"(expected false)"
)

print("TryUnlockZone(2) again, already unlocked:", ZoneAccessService.TryUnlockZone(player, 2), "(expected false)")
print("Coins unchanged after re-trigger:", profile.Coins, "(expected 100)")

profile.UnlockedZones = { 1 }
profile.Coins = 100000
print("TryUnlockZone(3) skipping zone 2:", ZoneAccessService.TryUnlockZone(player, 3), "(expected false)")
print("UnlockedZones unchanged after skip attempt:", table.concat(profile.UnlockedZones, ","), "(expected 1)")
```
Expected output, in order: `TryUnlockZone(2) with 100 coins (needs 500): false`, `UnlockedZones
unchanged: 1`, `TryUnlockZone(2) with 600 coins: true`, `Coins after unlock: 100`, `UnlockedZones after
unlock: 1,2`, `ZoneWall_2 collidable after unlock (should be passable/false): false`, `TryUnlockZone(2)
again, already unlocked: false`, `Coins unchanged after re-trigger: 100`, `TryUnlockZone(3) skipping
zone 2: false`, `UnlockedZones unchanged after skip attempt: 1`. Confirm via `get_console_output`.

- [ ] **Step 4: Commit**

```bash
git add src/ServerScriptService/Services/ZoneAccessService.lua
git commit -m "Add gate purchase handler to ZoneAccessService"
```

---

### Task 6: End-to-end Play-mode verification

**Files:** none (verification only).

**Interfaces:** none — this task exercises the full system built in Tasks 1-5 together.

- [ ] **Step 1: Fresh player, can't afford the gate**

Restart Play mode for a clean state. Run via `execute_luau` to confirm starting state:
```lua
local Players = game:GetService("Players")
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)

local player = Players:GetPlayers()[1]
local profile = PlayerDataService.Get(player)
print("Starting Coins:", profile.Coins, "(expected 0)")
print("Starting UnlockedZones:", table.concat(profile.UnlockedZones, ","), "(expected 1)")
```
Then use `character_navigation` to walk the test character north toward the Zone 2 gate
(`(10, 8, 30)`ish) and confirm via the Studio viewport/screenshot that the character stops at the
wall rather than passing through. Use `user_keyboard_input` to hold `E` on the gate's `UnlockPrompt`
(with the character close enough to trigger it), then re-check `profile.Coins` and
`profile.UnlockedZones` via `execute_luau` — both must be unchanged (silent rejection, per the
fail-closed rule), and the character must still be blocked by the wall.

- [ ] **Step 2: Affordable unlock, full flow**

Grant coins for this test only (not part of persisted game logic — same MCP live-edit precedent as the
prior persistence plan's testing steps):
```lua
local Players = game:GetService("Players")
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)
local player = Players:GetPlayers()[1]
PlayerDataService.Get(player).Coins = 1000
```
Use `character_navigation`/`user_keyboard_input` to walk to the gate and hold `E` on `UnlockPrompt`
again. Confirm via `execute_luau`:
```lua
local Players = game:GetService("Players")
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)
local player = Players:GetPlayers()[1]
local profile = PlayerDataService.Get(player)
print("Coins after real unlock:", profile.Coins, "(expected 500)")
print("UnlockedZones after real unlock:", table.concat(profile.UnlockedZones, ","), "(expected 1,2)")
```
Then physically walk the character through where the wall was — confirm no collision. Walk to the
Zone 2 table and pick up/eat the Sandwich via `user_keyboard_input`/`character_navigation`; confirm via
`execute_luau` that `leaderstats.Coins`/`leaderstats.Mass` increased by `ZoneConfig[2].CoinsPerBite`/
`MassPerBite` (5 and 0.5).

- [ ] **Step 3: Re-trigger after unlock**

With the gate now passable, trigger `UnlockPrompt` again (walk back to it, hold `E`). Confirm via
`execute_luau` that `profile.Coins` did not decrease again.

- [ ] **Step 4: Respawn persistence**

Trigger the test character's death (e.g. set `Humanoid.Health = 0` via `execute_luau`) and wait for
respawn. After respawn, physically confirm the Zone 2 wall is still passable (no bounce-back) — this
proves `onCharacterAdded`'s re-sync (Task 4) runs correctly on every respawn, not just the first spawn.

- [ ] **Step 5: Rejoin persistence**

Stop Play mode (fires save via `PlayerDataService`), start a fresh Play session with the same test
player. Confirm via `execute_luau` that `PlayerDataService.Get(player).UnlockedZones` already contains
`2` on load, then physically confirm the wall is passable from the very first spawn — no need to
re-trigger the prompt.

- [ ] **Step 6: Fail-closed defense in depth**

With a *different* freshly-reset profile (or by manually setting `profile.UnlockedZones = {1}` via
`execute_luau` on the current player without touching the wall's collision state — this deliberately
creates the "bypassed the wall via a non-physical means" scenario the design spec calls out), attempt
to trigger the Zone 2 `PickupPrompt` directly:
```lua
local Players = game:GetService("Players")
local FoodService = require(game.ServerScriptService.Services.FoodService)
local PlayerDataService = require(game.ServerScriptService.Services.PlayerDataService)

local player = Players:GetPlayers()[1]
PlayerDataService.Get(player).UnlockedZones = { 1 }

print("CanEatFromZone(2) with UnlockedZones reset to {1}:", FoodService.CanEatFromZone(player, 2), "(expected false)")
```
Expected: `false`. This confirms `FoodService`'s independent guard (Task 2) still blocks the eat even
when `UnlockedZones` doesn't match whatever the wall's `CollisionGroup` state happens to be — the two
systems don't trust each other, per the design spec's defense-in-depth requirement.

- [ ] **Step 7: Multi-player isolation (manual, optional)**

This property (one player's unlock doesn't affect another player standing at the same wall) is the
core thing `CollisionGroup`s exist to prove, but verifying it needs two simultaneous clients in the
same server — use Studio's Test tab "Clients and Servers" option (set to 2+ players) rather than MCP,
since that's a Studio-side multiplayer test feature the user drives directly. If run: have one client
unlock Zone 2, then confirm the second (still-locked) client still bounces off the same physical wall.
Note the result in this task's completion notes even if this step is skipped for time.

- [ ] **Step 8: Check server console**

Run `get_console_output` one final time across the whole session and confirm no unexpected warnings or
errors appeared during any of the above.

No commit for this task (verification only, no file changes).

---

### Task 7: Update `CLAUDE.md` to reflect the new service and folder

**Files:**
- Modify: `CLAUDE.md` (the "Roblox Eating Game" one, at the repo root)

**Interfaces:** none — documentation only, required per this project's own instructions ("this file
should always reflect the current source of truth, not the original plan").

- [ ] **Step 1: Add `ZoneAccessService.lua` to the Services listing**

Find:
```
      FoodService.lua         -- food pickup (ProximityPrompt) + eat (Tool.Activated) wiring
      GachaService.lua        -- crate pulls, pity, inventory grants
```
Replace with:
```
      FoodService.lua         -- food pickup (ProximityPrompt) + eat (Tool.Activated) wiring
      ZoneAccessService.lua   -- per-player CollisionGroup zone walls + unlock-gate purchase flow
      GachaService.lua        -- crate pulls, pity, inventory grants
```

- [ ] **Step 2: Add `ZoneGates/` to the Workspace listing**

Find:
```
  Workspace/
    FoodTables/                -- placeholder food table Parts, git-tracked as Rojo .model.json
```
Replace with:
```
  Workspace/
    FoodTables/                -- placeholder food table Parts, git-tracked as Rojo .model.json
    ZoneGates/                  -- per-zone unlock wall/gate Models, git-tracked as Rojo .model.json
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md to reflect zone-unlock gating"
```

---

## Self-Review Notes

**Spec coverage:** `PlayerDataService.SpendCoins`/`UnlockZone` (Task 1) — spec's "two new
`PlayerDataService` methods" section. `FoodService` defense-in-depth (Task 2) — spec's "Defense in
depth in `FoodService`" section, plus a folder-scoping fix the spec didn't call out explicitly but
which Task 3's assets would otherwise break (documented inline in Task 2). Zone 2 physical assets
(Task 3) — spec's "New Workspace/ReplicatedStorage assets" section. Per-player `CollisionGroup`
infrastructure (Task 4) — spec's "Per-player wall passability via CollisionGroups" and "Join/respawn"
data-flow sections. Gate purchase flow with all three guards (already-unlocked, sequential, coins) and
the collision flip (Task 5) — spec's "Unlock purchase flow" section. Full manual testing plan (Task 6)
— spec's "Testing / Verification Plan" section, all 9 original steps mapped to Task 6's 8 steps (step 7
here — multi-player isolation — is flagged as manual/optional since it needs Studio's own multi-client
test feature, not MCP). `CLAUDE.md` currency (Task 7) — per this project's own standing rule, same
pattern as the prior persistence plan's Task 2.

**Placeholder scan:** no TBD/TODO. Task 6 Step 7 explicitly notes it may be skipped for time rather
than silently omitting it — that's an honest scope note (same pattern as the prior plan's untestable
DataStore-failure path), not a placeholder.

**Type consistency:** `PlayerDataService.SpendCoins(player, amount): boolean` and
`.UnlockZone(player, zoneId)` (Task 1) are used with identical signatures in Task 5's
`TryUnlockZone`. `FoodService.CanEatFromZone(player, zoneId): boolean` (Task 2) is used identically in
Task 6 Step 6. `ZoneAccessService.TryUnlockZone(player, zoneId): boolean` (Task 5) matches its use in
Task 6 Steps 1-3. `zoneWallGroups`/`playerGroupName` are defined once in Task 4 and consumed as-is
(same file, no signature change) in Task 5 — confirmed by re-reading Task 4 Step 1's full file listing
against Task 5 Step 2's additions.
