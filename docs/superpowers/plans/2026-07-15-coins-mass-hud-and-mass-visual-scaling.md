# Coins/Mass HUD and Mass Visual Scaling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give players a visible Coins/Mass HUD, and make `Mass` visually transform their avatar from
a stick-figure-thin R15 character at 0 Mass into an exaggerated, "brainrot"-level fat character
(up to 20x width/depth) as Mass approaches 1 billion — with the raw `Mass` number (and the future
leaderboard built on it) continuing to climb uncapped past that point.

**Architecture:** A new server-side `MassVisualService.lua` reads the same `leaderstats.Mass` value
`PlayerDataService` already keeps live, maps it through a linear-with-cap formula onto each R15
character's `Humanoid.BodyWidthScale`/`BodyDepthScale` child `NumberValue`s, snapping instantly on
spawn/respawn and tweening smoothly on live Mass gains. A new client-side `CurrencyHUDController.lua`
(this project's first client controller, requiring a new minimal `Init.client.lua` boot script) reads
`leaderstats.Coins`/`.Mass` directly and renders a top-right pill display — no new `RemoteEvent`s
needed for either feature, since both read data that already replicates.

**Tech Stack:** Luau (Roblox), `Humanoid` R15 body-scale `NumberValue`s (`BodyWidthScale`,
`BodyDepthScale`), `TweenService`, `leaderstats` (existing `PlayerDataService` replication), Roblox
Studio MCP connection for live verification.

**No automated test framework exists in this repo** (no TestEZ, no CI), consistent with prior plans.
Every task's "test" step is: write the code, then exercise it live via the Roblox Studio MCP
`execute_luau` tool against a running Play-mode session (confirming output via `get_console_output`),
plus `screen_capture` for the HUD's visual layout, which `execute_luau` (server-context) cannot inspect
directly since `PlayerGui` content lives client-side.

## Global Constraints

- No script outside `EconomyService`/`PlayerDataService` mutates Coins/Mass (per `CLAUDE.md`) —
  `MassVisualService` only **reads** `leaderstats.Mass`; it never writes `Coins`/`Mass`/`DataStore`.
- Server-authoritative: `BodyWidthScale`/`BodyDepthScale` are set exclusively by the new server-side
  `MassVisualService` — no client script ever sets them.
- No new `RemoteEvent`s — both features read data that already replicates via `leaderstats`, per the
  explicit design-spec decision.
- PascalCase for scripts/modules, camelCase for variables/functions, ALL_CAPS for constants (per
  `CLAUDE.md`).
- Only `BodyWidthScale`/`BodyDepthScale` are driven by Mass — `HeadScale` is left untouched (produces a
  huge body with a normal-sized head at the high end; confirmed as the intended look, not a bug).
- Prerequisite already done by the user (not validated at runtime beyond a defensive `RigType` check):
  Studio Game Settings → Avatar → `Avatar Type` = R15, `Avatar Scaling` = Consistent.

**Design spec:** `docs/superpowers/specs/2026-07-15-coins-mass-hud-and-mass-visual-scaling-design.md` —
read this first for full rationale, including the "Open Tuning Note" flagging `MASS_AT_MAX_SCALE` as a
first-pass placeholder pending real playtest data.

---

### Task 1: `MassVisualConfig.lua` + `MassVisualService.lua` — server-side body scaling

**Files:**
- Create: `src/ReplicatedStorage/Modules/Config/MassVisualConfig.lua`
- Create: `src/ServerScriptService/Services/MassVisualService.lua`
- Modify: `src/ServerScriptService/Init.server.lua`

**Interfaces:**
- Consumes: `ReplicatedStorage.Modules.Config` (existing folder), `Players` service, the existing
  `leaderstats.Mass` `NumberValue` created by `PlayerDataService` (read-only, no changes to
  `PlayerDataService` in this task).
- Produces: `MassVisualConfig` (module table: `MIN_WIDTH_SCALE`, `MIN_DEPTH_SCALE`,
  `MAX_WIDTH_SCALE`, `MAX_DEPTH_SCALE`, `MASS_AT_MAX_SCALE`, `TWEEN_TIME_SEC`),
  `MassVisualService.Start()` — the only function called from `Init.server.lua`.

- [ ] **Step 1: Create `MassVisualConfig.lua`**

`src/ReplicatedStorage/Modules/Config/MassVisualConfig.lua`:
```lua
-- MassVisualConfig.lua
-- Tunables for the Mass -> body-scale mapping. MASS_AT_MAX_SCALE is a first-pass placeholder
-- pending real playtest data on Mass-accumulation rates -- see the design spec's "Open Tuning Note".

return {
	MIN_WIDTH_SCALE = 0.7,
	MIN_DEPTH_SCALE = 0.7,
	MAX_WIDTH_SCALE = 20,
	MAX_DEPTH_SCALE = 20,
	MASS_AT_MAX_SCALE = 1000000000,
	TWEEN_TIME_SEC = 0.6,
}
```

- [ ] **Step 2: Create `MassVisualService.lua`**

`src/ServerScriptService/Services/MassVisualService.lua`:
```lua
-- MassVisualService.lua
-- Owns the Mass -> body-scale (BodyWidthScale/BodyDepthScale) visual mapping. Read-only against
-- leaderstats.Mass -- never mutates Coins/Mass or touches DataStore. No other script sets
-- BodyWidthScale/BodyDepthScale.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local MassVisualConfig = require(ReplicatedStorage.Modules.Config.MassVisualConfig)

local MassVisualService = {}

-- Humanoid -> { Width = Tween, Depth = Tween }, weak-keyed so entries are GC'd when a Humanoid is
-- destroyed (respawn/leave).
local activeTweens = setmetatable({}, { __mode = "k" })

local function massToScale(mass)
	local t = math.clamp(mass / MassVisualConfig.MASS_AT_MAX_SCALE, 0, 1)
	local width = MassVisualConfig.MIN_WIDTH_SCALE
		+ (MassVisualConfig.MAX_WIDTH_SCALE - MassVisualConfig.MIN_WIDTH_SCALE) * t
	local depth = MassVisualConfig.MIN_DEPTH_SCALE
		+ (MassVisualConfig.MAX_DEPTH_SCALE - MassVisualConfig.MIN_DEPTH_SCALE) * t
	return width, depth
end

local function currentMass(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	local mass = leaderstats and leaderstats:FindFirstChild("Mass")
	return mass and mass.Value or 0
end

local function onCharacterAdded(player, character)
	local humanoid = character:WaitForChild("Humanoid")
	if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return
	end

	humanoid.AutomaticScalingEnabled = true

	local widthScale = humanoid:WaitForChild("BodyWidthScale", 5)
	local depthScale = humanoid:WaitForChild("BodyDepthScale", 5)
	if not widthScale or not depthScale then
		return
	end

	local width, depth = massToScale(currentMass(player))
	widthScale.Value = width
	depthScale.Value = depth
end

local function onMassChanged(player, newMass)
	local character = player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return
	end

	local widthScale = humanoid:FindFirstChild("BodyWidthScale")
	local depthScale = humanoid:FindFirstChild("BodyDepthScale")
	if not widthScale or not depthScale then
		return
	end

	local existing = activeTweens[humanoid]
	if existing then
		existing.Width:Cancel()
		existing.Depth:Cancel()
	end

	local width, depth = massToScale(newMass)
	local tweenInfo = TweenInfo.new(MassVisualConfig.TWEEN_TIME_SEC)
	local widthTween = TweenService:Create(widthScale, tweenInfo, { Value = width })
	local depthTween = TweenService:Create(depthScale, tweenInfo, { Value = depth })
	activeTweens[humanoid] = { Width = widthTween, Depth = depthTween }
	widthTween:Play()
	depthTween:Play()
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end

	task.spawn(function()
		local leaderstats = player:WaitForChild("leaderstats")
		local mass = leaderstats:WaitForChild("Mass")
		mass.Changed:Connect(function(newMass)
			onMassChanged(player, newMass)
		end)
	end)
end

function MassVisualService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return MassVisualService
```

- [ ] **Step 3: Wire into `Init.server.lua`**

In `src/ServerScriptService/Init.server.lua`, find:
```lua
local PlayerDataService = require(Services.PlayerDataService)
local ZoneAccessService = require(Services.ZoneAccessService)
local EconomyService = require(Services.EconomyService)
local FoodService = require(Services.FoodService)
```
Replace with:
```lua
local PlayerDataService = require(Services.PlayerDataService)
local MassVisualService = require(Services.MassVisualService)
local ZoneAccessService = require(Services.ZoneAccessService)
local EconomyService = require(Services.EconomyService)
local FoodService = require(Services.FoodService)
```
Find:
```lua
PlayerDataService.Start()
ZoneAccessService.Start()
EconomyService.Start()
FoodService.Start()
```
Replace with:
```lua
PlayerDataService.Start()
MassVisualService.Start()
ZoneAccessService.Start()
EconomyService.Start()
FoodService.Start()
```

- [ ] **Step 4: Verify via MCP against a running Play session**

Start Play mode via `start_stop_play`, then run via `execute_luau`:
```lua
local Players = game:GetService("Players")
local MassVisualConfig = require(game.ReplicatedStorage.Modules.Config.MassVisualConfig)

local player = Players:GetPlayers()[1]
assert(player, "No test player in this Play session")

local humanoid = player.Character:WaitForChild("Humanoid")
print("RigType:", humanoid.RigType.Name, "(expected R15)")

local widthScale = humanoid:WaitForChild("BodyWidthScale")
local depthScale = humanoid:WaitForChild("BodyDepthScale")

print("Fresh spawn (Mass=0) BodyWidthScale:", widthScale.Value, "(expected", MassVisualConfig.MIN_WIDTH_SCALE, ")")
print("Fresh spawn (Mass=0) BodyDepthScale:", depthScale.Value, "(expected", MassVisualConfig.MIN_DEPTH_SCALE, ")")

-- Mid-range Mass: 500,000,000 is exactly half of MASS_AT_MAX_SCALE (1,000,000,000)
player.leaderstats.Mass.Value = 500000000
task.wait(MassVisualConfig.TWEEN_TIME_SEC + 0.5)
print("Mid Mass BodyWidthScale after tween:", widthScale.Value, "(expected ~10.35)")
print("Mid Mass BodyDepthScale after tween:", depthScale.Value, "(expected ~10.35)")

-- Beyond the cap: 2,000,000,000 must clamp at MAX, not exceed it
player.leaderstats.Mass.Value = 2000000000
task.wait(MassVisualConfig.TWEEN_TIME_SEC + 0.5)
print("Over-cap Mass BodyWidthScale after tween:", widthScale.Value, "(expected exactly", MassVisualConfig.MAX_WIDTH_SCALE, ")")
print("Over-cap Mass BodyDepthScale after tween:", depthScale.Value, "(expected exactly", MassVisualConfig.MAX_DEPTH_SCALE, ")")
```
Expected output: `RigType: R15`, both fresh-spawn scales at `0.7`, both mid-Mass scales at
approximately `10.35` (allow ±0.05 for tween completion timing), both over-cap scales at exactly `20`.
Confirm via `get_console_output`, no warnings.

Then verify respawn snaps instantly (no tween) while Mass is still at the capped value:
```lua
local Players = game:GetService("Players")
local player = Players:GetPlayers()[1]

player.Character.Humanoid.Health = 0
local newCharacter = player.CharacterAdded:Wait()
task.wait(0.2) -- small buffer for MassVisualService's own CharacterAdded handler to finish
local humanoid = newCharacter:WaitForChild("Humanoid")
local widthScale = humanoid:WaitForChild("BodyWidthScale")
print("BodyWidthScale immediately after respawn:", widthScale.Value, "(expected already 20, not 0.7 -- proves snap, not tween)")
```
Expected: `20` immediately, confirming the fresh character snaps to the current Mass's scale rather
than starting skinny and tweening up.

- [ ] **Step 5: Commit**

```bash
git add src/ReplicatedStorage/Modules/Config/MassVisualConfig.lua src/ServerScriptService/Services/MassVisualService.lua src/ServerScriptService/Init.server.lua
git commit -m "Add MassVisualService: Mass-driven R15 body scaling"
```

---

### Task 2: `CurrencyHUDController.lua` + `Init.client.lua` — Coins/Mass HUD

**Files:**
- Create: `src/StarterPlayer/StarterPlayerScripts/Controllers/CurrencyHUDController.lua`
- Create: `src/StarterPlayer/StarterPlayerScripts/Init.client.lua`

**Interfaces:**
- Consumes: existing `leaderstats.Coins`/`.Mass` (created by `PlayerDataService`, replicated to the
  owning client automatically — no changes to `PlayerDataService` in this task).
- Produces: `CurrencyHUDController.Start()` — called by the new `Init.client.lua`, this project's
  first client boot script (`StarterPlayerScripts` currently only holds a `.gitkeep`).

- [ ] **Step 1: Create `CurrencyHUDController.lua`**

`src/StarterPlayer/StarterPlayerScripts/Controllers/CurrencyHUDController.lua`:
```lua
-- CurrencyHUDController.lua
-- Builds and keeps the top-right Coins/Mass HUD in sync with the local player's leaderstats.
-- Read-only against leaderstats -- never requests or computes currency values itself.

local Players = game:GetService("Players")

local CurrencyHUDController = {}

local player = Players.LocalPlayer

local function insertCommas(digits)
	local left, num, right = digits:match("^([^%d]*%d)(%d*)(.-)$")
	return left .. num:reverse():gsub("(%d%d%d)", "%1,"):reverse() .. right
end

local function formatNumber(value, decimals)
	if value >= 1000000000 then
		return string.format("%.1fB", value / 1000000000)
	elseif value >= 1000000 then
		return string.format("%.1fM", value / 1000000)
	end

	local whole = math.floor(value)
	local wholeStr = insertCommas(tostring(whole))

	if decimals > 0 then
		local fracStr = string.format("%." .. decimals .. "f", value - whole)
		return wholeStr .. fracStr:sub(2)
	end

	return wholeStr
end

local function buildHUD()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "CurrencyHUD"
	screenGui.ResetOnSpawn = false

	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.AnchorPoint = Vector2.new(1, 0)
	pill.Position = UDim2.new(1, -12, 0, 12)
	pill.Size = UDim2.new(0, 150, 0, 60)
	pill.BackgroundColor3 = Color3.new(0, 0, 0)
	pill.BackgroundTransparency = 0.45
	pill.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = pill

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.Padding = UDim.new(0, 2)
	layout.Parent = pill

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = pill

	local coinsLabel = Instance.new("TextLabel")
	coinsLabel.Name = "CoinsLabel"
	coinsLabel.Size = UDim2.new(1, 0, 0, 24)
	coinsLabel.BackgroundTransparency = 1
	coinsLabel.TextColor3 = Color3.new(1, 1, 1)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Right
	coinsLabel.Font = Enum.Font.GothamBold
	coinsLabel.TextSize = 18
	coinsLabel.Text = "0 🪙"
	coinsLabel.Parent = pill

	local massLabel = Instance.new("TextLabel")
	massLabel.Name = "MassLabel"
	massLabel.Size = UDim2.new(1, 0, 0, 24)
	massLabel.BackgroundTransparency = 1
	massLabel.TextColor3 = Color3.new(1, 1, 1)
	massLabel.TextXAlignment = Enum.TextXAlignment.Right
	massLabel.Font = Enum.Font.GothamBold
	massLabel.TextSize = 18
	massLabel.Text = "0.0 ⚖️"
	massLabel.Parent = pill

	screenGui.Parent = player:WaitForChild("PlayerGui")

	return coinsLabel, massLabel
end

function CurrencyHUDController.Start()
	local coinsLabel, massLabel = buildHUD()

	local leaderstats = player:WaitForChild("leaderstats")
	local coins = leaderstats:WaitForChild("Coins")
	local mass = leaderstats:WaitForChild("Mass")

	local function updateCoins()
		coinsLabel.Text = formatNumber(coins.Value, 0) .. " 🪙"
	end

	local function updateMass()
		massLabel.Text = formatNumber(mass.Value, 1) .. " ⚖️"
	end

	coins.Changed:Connect(updateCoins)
	mass.Changed:Connect(updateMass)

	updateCoins()
	updateMass()
end

return CurrencyHUDController
```

- [ ] **Step 2: Create `Init.client.lua`**

`src/StarterPlayer/StarterPlayerScripts/Init.client.lua`:
```lua
-- Init.client.lua
-- Boot sequence: requires and starts every client Controller.

local Controllers = script.Parent.Controllers

local CurrencyHUDController = require(Controllers.CurrencyHUDController)

CurrencyHUDController.Start()
```

- [ ] **Step 3: Verify via MCP**

Restart Play mode (so Rojo syncs the new files and the new `LocalScript` runs), then set test values via
`execute_luau` (server-context, matching this project's existing precedent for live-editing test data):
```lua
local Players = game:GetService("Players")
local player = Players:GetPlayers()[1]
assert(player, "No test player in this Play session")

player.leaderstats.Coins.Value = 1250
player.leaderstats.Mass.Value = 340.5
print("Set Coins to 1250 and Mass to 340.5 for HUD verification")
```
Then use `screen_capture` to visually confirm the top-right pill shows `1,250 🪙` and `340.5 ⚖️`,
stacked vertically, right-aligned, matching the approved Option B mockup layout.

Also set a large value to confirm abbreviation:
```lua
local Players = game:GetService("Players")
local player = Players:GetPlayers()[1]
player.leaderstats.Coins.Value = 2500000000
player.leaderstats.Mass.Value = 1500000000
```
`screen_capture` again to confirm the pill now shows `2.5B 🪙` and `1.5B ⚖️`.

- [ ] **Step 4: Commit**

```bash
git add src/StarterPlayer/StarterPlayerScripts/Controllers/CurrencyHUDController.lua src/StarterPlayer/StarterPlayerScripts/Init.client.lua
git commit -m "Add Coins/Mass HUD (top-right pill)"
```

---

### Task 3: End-to-end Play-mode verification

**Files:** none (verification only).

**Interfaces:** none — this task exercises the full system built in Tasks 1-2 together, plus the
20x-cap physical/visual sanity check flagged in the design spec.

- [ ] **Step 1: Fresh player, full HUD + skinny body**

Restart Play mode for a clean state. Via `execute_luau`, confirm starting state:
```lua
local Players = game:GetService("Players")
local player = Players:GetPlayers()[1]
print("Starting Coins:", player.leaderstats.Coins.Value, "(expected 0)")
print("Starting Mass:", player.leaderstats.Mass.Value, "(expected 0)")

local humanoid = player.Character:WaitForChild("Humanoid")
print("Starting BodyWidthScale:", humanoid.BodyWidthScale.Value, "(expected 0.7)")
```
`screen_capture` to confirm the HUD pill shows `0 🪙` / `0.0 ⚖️`, and the character visually reads as
stick-figure-thin.

- [ ] **Step 2: Real eating gradually widens the character and updates the HUD**

Use `character_navigation`/`user_keyboard_input` to walk to the Zone 1 table and eat a few Broccoli
(as in prior plans' testing steps). After each eat, `screen_capture` to confirm the HUD numbers tick up
and the character's body visibly (if subtly, at these low Mass values) widens with a smooth tween
rather than an instant pop.

- [ ] **Step 3: Extreme Mass — the 20x "brainrot" cap**

Via `execute_luau`, push the test player to and past the cap:
```lua
local Players = game:GetService("Players")
local player = Players:GetPlayers()[1]
player.leaderstats.Mass.Value = 1200000000
task.wait(1.2)
```
`screen_capture` to visually confirm the character is now dramatically, exaggeratedly wide/fat (the
intended "brainrot" look), and the HUD shows `1.2B ⚖️`.

Then physically test the flagged risk from the design spec: use `character_navigation` to walk the
now-massive character through the existing `Zone2Gate` opening and near the `Baseplate` edges.
`screen_capture` throughout. Confirm:
- The character doesn't get permanently stuck/wedged in existing geometry.
- The camera doesn't clip through the character's body in a way that blocks the player's view entirely.

If either problem occurs, note it — the design spec flagged this as an expected manual-test checkpoint,
not a guaranteed-safe assumption; a follow-up adjustment (e.g. a slightly lower practical cap, or camera
distance tuning) would be a small follow-up task, not a re-design.

- [ ] **Step 4: Returning high-Mass player spawns correctly sized immediately**

With the test player still at `Mass = 1,200,000,000`, stop Play mode (fires save), then start a fresh
Play session with the same test player. Via `execute_luau` immediately after spawn:
```lua
local Players = game:GetService("Players")
local player = Players:GetPlayers()[1]
local humanoid = player.Character:WaitForChild("Humanoid")
print("BodyWidthScale on fresh join at high Mass:", humanoid.BodyWidthScale.Value, "(expected 20, not 0.7)")
```
Expected: `20` immediately — confirms a returning high-Mass player never appears skinny even for a
moment before growing.

- [ ] **Step 5: Check console**

Run `get_console_output` across the whole session and confirm no unexpected warnings or errors appeared
during any of the above (particularly watch for `AutomaticScalingEnabled`-related warnings or tween
errors).

No commit for this task (verification only, no file changes).

---

### Task 4: Update `CLAUDE.md` to reflect the new services/controllers

**Files:**
- Modify: `CLAUDE.md` (the "Roblox Eating Game" one, at the repo root)

**Interfaces:** none — documentation only, required per this project's own instructions ("this file
should always reflect the current source of truth, not the original plan").

- [ ] **Step 1: Add `MassVisualService.lua` to the Services listing**

Find:
```
      FoodService.lua         -- food pickup (ProximityPrompt) + eat (Tool.Activated) wiring
      ZoneAccessService.lua   -- per-player CollisionGroup zone walls + unlock-gate purchase flow
```
Replace with:
```
      FoodService.lua         -- food pickup (ProximityPrompt) + eat (Tool.Activated) wiring
      ZoneAccessService.lua   -- per-player CollisionGroup zone walls + unlock-gate purchase flow
      MassVisualService.lua   -- Mass-driven R15 BodyWidthScale/BodyDepthScale visual scaling
```

- [ ] **Step 2: Add `MassVisualConfig.lua` to the Config listing**

Find:
```
        RebirthConfig.lua
        GameplayConfig.lua    -- non-zone-specific tunables (e.g. EAT_COOLDOWN_SEC)
```
Replace with:
```
        RebirthConfig.lua
        GameplayConfig.lua    -- non-zone-specific tunables (e.g. EAT_COOLDOWN_SEC)
        MassVisualConfig.lua  -- Mass -> body-scale mapping tunables (min/max scale, cap, tween time)
```

- [ ] **Step 3: Expand the `StarterPlayerScripts/` listing**

Find:
```
  StarterPlayer/
    StarterPlayerScripts/      -- client-side UI/controllers
```
Replace with:
```
  StarterPlayer/
    StarterPlayerScripts/
      Init.client.lua          -- boot sequence, requires + starts every client Controller
      Controllers/
        CurrencyHUDController.lua -- top-right Coins/Mass HUD, reads leaderstats directly
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md to reflect Coins/Mass HUD and Mass visual scaling"
```

---

## Self-Review Notes

**Spec coverage:** `MassVisualConfig.lua` (Task 1 Step 1) — spec's "New config" section, all six
values match exactly. `MassVisualService.lua` (Task 1 Step 2) — spec's "Component Details" section:
snap-on-`CharacterAdded`, tween-and-retarget on `leaderstats.Mass.Changed`, weak-keyed tween tracking,
defensive R15/nil guards, `AutomaticScalingEnabled` (an implementation detail the spec didn't call out
explicitly but which is required for the scaling to have any visual effect at all — confirmed via
Roblox documentation during brainstorming). `Init.server.lua` wiring (Task 1 Step 3) — spec's "New
service... `MassVisualService.Start()`" integration note. `CurrencyHUDController.lua` +
`Init.client.lua` (Task 2) — spec's "Coins/Mass HUD" architecture and data-flow sections, including the
approved Option B (top-right, stacked, icon-after-value) layout and the K/M/B + comma formatting rules.
Full end-to-end verification including the 20x physical/camera sanity check (Task 3) — spec's
"Testing / Verification Plan" section, all 10 original steps mapped across Task 3's 5 steps (steps 2-3
and 6-8 of the spec's list are combined where they test the same live session state). `CLAUDE.md`
currency (Task 4) — per this project's own standing rule, same pattern as the prior zone-gating plan's
final task.

**Placeholder scan:** no TBD/TODO. `MASS_AT_MAX_SCALE`'s placeholder status is an explicit, named
design decision (see "Open Tuning Note" in the spec and the comment in `MassVisualConfig.lua` itself),
not an unfinished plan step. Task 3 Step 3's "if either problem occurs, note it" is an honest
contingency note (mirrors the prior zone-gating plan's Task 6 Step 7 pattern for an optional/manual
check), not a vague placeholder — no code or verification step is left unwritten.

**Type consistency:** `MassVisualConfig`'s six keys (`MIN_WIDTH_SCALE`, `MIN_DEPTH_SCALE`,
`MAX_WIDTH_SCALE`, `MAX_DEPTH_SCALE`, `MASS_AT_MAX_SCALE`, `TWEEN_TIME_SEC`) are defined once in Task 1
Step 1 and referenced with identical names in Task 1 Step 2's `massToScale` and in every Task 1/3
verification script. `MassVisualService.Start()` (Task 1 Step 2) matches its call site in Task 1 Step 3.
`CurrencyHUDController.Start()` (Task 2 Step 1) matches its call site in Task 2 Step 2's
`Init.client.lua`. `formatNumber(value, decimals)` and `insertCommas(digits)` are only used internally
within `CurrencyHUDController.lua`, consumed consistently by `updateCoins`/`updateMass` with the
documented `(0)`/`(1)` decimal arguments.
