# Coins/Mass HUD + Mass Visual Scaling — Design Spec

Date: 2026-07-15
Status: Approved for planning

## Purpose

Two related client-facing features, both driven by the existing `Coins`/`Mass` `leaderstats` values:

1. **Coins/Mass HUD** — a persistent on-screen display so players can actually see their currencies (currently invisible except via the default Roblox leaderboard).
2. **Mass Visual Scaling** — make a player's avatar visibly reflect their `Mass`: a stick-figure-thin look at 0 Mass, growing progressively (and eventually absurdly) wider/rounder as Mass increases, with no upper bound on Mass itself but a hard visual cap.

Mass Visual Scaling is intentionally exaggerated for shock value, replayability, and as a monetization hook (the 2x Mass gamepass and repeated Rebirths are the fast path to a bigger look) — see the growth curve discussion below.

## Out of Scope (explicitly deferred)

- **Zone name / progress indicators, Rebirth count, or any other HUD element.** Only Coins + Mass, per explicit scope decision — keep it minimal, extend later once Rebirth/Gacha need their own UI.
- **Head scaling.** Only `BodyWidthScale`/`BodyDepthScale` are driven by Mass; `HeadScale` is left untouched. At the high end this deliberately produces a huge body with a normal-sized head — confirmed as the intended "brainrot" aesthetic, not a bug to fix.
- **Exact final tuning of `MASS_AT_MAX_SCALE` and the growth curve shape.** See "Open Tuning Note" below — shipped with explicit user-provided placeholder values, expected to be revisited after real playtesting data exists on Mass-accumulation rates.
- **Mesh/accessory-based fatness tiers.** Rejected during brainstorming in favor of `Humanoid` BodyScale properties — no art dependency, works with any equipped avatar/outfit.
- **Any new RemoteEvent.** Both features are read-only against data that already replicates (`leaderstats`), so no new client→server or server→client remote is needed.

## Open Tuning Note (flag, don't silently resolve)

The user's stated intent: a free player grinding + rebirthing for a few days/weeks should reach a "very exaggerated" size, while the true 20x cap should realistically require ~1 billion Mass — reachable only via heavy spend (2x Mass gamepass) or extended AFK/grinding. With a **strictly linear** ramp from 0 to 1,000,000,000, a free player's Mass total after a few weeks may only represent a small percentage of that range, which could look less exaggerated early on than intended. This is flagged explicitly rather than guessed around: `MASS_AT_MAX_SCALE` and the linear formula below should be treated as a **first pass**, to be re-tuned (or reshaped into a curve) after playtesting reveals real Mass-accumulation rates. This mirrors the existing placeholder treatment of `RebirthConfig`'s threshold values.

## Prerequisites (already done by user)

Studio Game Settings → Avatar: `Avatar Type` = R15, `Avatar Scaling` = Consistent (not Player Choice). This normalizes every player's base proportions before script-driven scaling is layered on top, which is required for the Mass Visual system to look consistent across players. No code depends on detecting this — it's a Studio configuration prerequisite, not something validated at runtime beyond the defensive RigType check below.

## Architecture

### Coins/Mass HUD

Pure client-side, no new remotes. New `StarterPlayer/StarterPlayerScripts/Controllers/CurrencyHUDController.lua`:
- Builds a `ScreenGui` with a single top-right pill (approved layout: stacked Coins on top, Mass below, dark rounded background, icon + value per row, right-aligned).
- Reads `player.leaderstats.Coins`/`.Mass` (already created and kept live by `PlayerDataService`) via `WaitForChild`, then updates label text on `.Changed`.
- Formatting: Coins/Mass under 1,000,000 shown with thousands separators (e.g. `1,250`); Mass additionally shown to 1 decimal below that threshold (e.g. `340.5`). Values at or above 1,000,000 shown abbreviated (`1.2M`, `3.4B`) — required given Mass is expected to reach billions per the visual-scaling design.

### Mass Visual Scaling

New config `ReplicatedStorage/Modules/Config/MassVisualConfig.lua`:
```lua
return {
    MIN_WIDTH_SCALE = 0.7,
    MIN_DEPTH_SCALE = 0.7,
    MAX_WIDTH_SCALE = 20,
    MAX_DEPTH_SCALE = 20,
    MASS_AT_MAX_SCALE = 1000000000, -- 1 billion; see "Open Tuning Note"
    TWEEN_TIME_SEC = 0.6,
}
```

New service `ServerScriptService/Services/MassVisualService.lua`. Formula (pure function, no side effects):
```lua
local function massToScale(mass)
    local t = math.clamp(mass / Config.MASS_AT_MAX_SCALE, 0, 1)
    local width = Config.MIN_WIDTH_SCALE + (Config.MAX_WIDTH_SCALE - Config.MIN_WIDTH_SCALE) * t
    local depth = Config.MIN_DEPTH_SCALE + (Config.MAX_DEPTH_SCALE - Config.MIN_DEPTH_SCALE) * t
    return width, depth
end
```

`MassVisualService` never mutates `Coins`/`Mass` or touches `DataStore` — it only **reads** the same `leaderstats.Mass` value `PlayerDataService` already keeps live, and **writes** `Humanoid.BodyWidthScale`/`BodyDepthScale`. This keeps it a pure observer, consistent with the project rule that only `EconomyService`/`PlayerDataService` mutate Coins/Mass.

## Data Flow

**HUD:** `EconomyService`/`PlayerDataService` grant Mass/Coins (existing, unchanged) → `leaderstats` values update (existing, unchanged) → replicate to owning client automatically (default Roblox behavior for `Player` descendants) → `CurrencyHUDController`'s `.Changed` listener fires → label re-rendered with formatted text.

**Mass Visual:**
1. `Players.PlayerAdded` → `MassVisualService` waits for `leaderstats.Mass`, connects `.Changed`, and connects `player.CharacterAdded`.
2. **On `CharacterAdded`** (initial spawn or respawn): read the current `Mass` value, compute target scale via `massToScale`, and **snap-apply instantly** (no tween) to the fresh `Humanoid`. This ensures a returning high-Mass player is never seen briefly skinny before growing.
3. **On subsequent `leaderstats.Mass.Changed`** (live gains from eating): compute new target scale, cancel any in-flight tween for that player's current `Humanoid`, and start a new `TweenService` tween from the current interpolated value to the new target over `TWEEN_TIME_SEC`. Rapid repeated eating simply keeps retargeting the same tween rather than queuing.
4. `BodyWidthScale`/`BodyDepthScale` are standard replicated `Humanoid` properties — every client (including spectators) sees the result automatically, no extra remote needed.

## Component Details

### `MassVisualConfig.lua` (new)
As shown above. All five values are tunable constants; no logic script hardcodes them.

### `MassVisualService.lua` (new)
- `Start()`: connects `Players.PlayerAdded` → `onPlayerAdded`; iterates existing players (mirrors the late-boot pattern used elsewhere in this codebase, e.g. `PlayerDataService.Start`).
- `onPlayerAdded(player)`:
  - Connects `player.CharacterAdded:Connect(function(character) onCharacterAdded(player, character) end)`; if `player.Character` already exists, call it immediately.
  - `task.spawn`s a `WaitForChild("leaderstats"):WaitForChild("Mass")` wait, then connects `Mass.Changed:Connect(function(newMass) onMassChanged(player, newMass) end)`.
- `onCharacterAdded(player, character)`: waits for `Humanoid`, reads current `Mass` value off `leaderstats`, computes scale, sets `BodyWidthScale`/`BodyDepthScale` directly (snap, no tween).
- `onMassChanged(player, newMass)`: resolves `player.Character`'s current `Humanoid` (no-op if character/humanoid missing, or `Humanoid.RigType ~= Enum.HumanoidRigType.R15` — defensive only, shouldn't trigger given the Studio Avatar Type setting), computes new target scale, cancels any existing tween tracked for that `Humanoid` (stored in a weak-keyed table so entries are GC'd automatically when a `Humanoid` is destroyed on respawn/leave), and plays a new `TweenService` tween toward the target.

### `CurrencyHUDController.lua` (new)
- `Start()`: builds the `ScreenGui`/pill UI once, waits for `leaderstats`/`Coins`/`Mass`, sets initial text, connects `.Changed` on both.
- Local `formatNumber(n, decimals)` helper: abbreviates (`K`/`M`/`B`) at ≥1,000,000, otherwise comma-separates with the given decimal count (0 for Coins, 1 for Mass).

### `Init.server.lua` (modified)
- Add `require(Services.MassVisualService)` and `MassVisualService.Start()` to the boot sequence, after `PlayerDataService`.

### `StarterPlayer/StarterPlayerScripts/Init.client.lua` (new)
- No client boot script exists yet in this project (`StarterPlayerScripts` currently only holds a `.gitkeep`) — `CurrencyHUDController` is the first client controller, so this is a new minimal `LocalScript` that requires and starts it, mirroring `ServerScriptService/Init.server.lua`'s boot pattern.

## Error Handling

- **Character not loaded when `PlayerAdded` fires:** handled by the `CharacterAdded` connection plus an immediate check for an already-existing `player.Character`.
- **`leaderstats` not yet created:** `WaitForChild` yields safely rather than busy-polling; both the HUD and `MassVisualService` use this pattern.
- **Rapid Mass gains (fast eating in high zones):** new tweens retarget/replace the in-flight tween per `Humanoid` rather than queuing, avoiding a stutter of backlogged tweens.
- **Player leaves or respawns mid-tween:** tween tracking table is weak-keyed on `Humanoid`, so a destroyed `Humanoid`'s entry is garbage collected automatically — no manual cleanup needed, no leak.
- **Non-R15 character:** `onMassChanged` and `onCharacterAdded` both no-op silently if `Humanoid.RigType` isn't R15 — shouldn't occur given the Studio Avatar Type setting, but defensive rather than erroring.
- **Very large Coins/Mass values in the HUD:** abbreviated formatting (`K`/`M`/`B`) prevents the pill from overflowing or displaying unreadable raw digit counts once Mass reaches the billions this design targets.
- **Extreme 20x scale physical sanity:** not a code-level error case, but flagged as a required manual Studio test before shipping — confirm the character doesn't get stuck in existing `ZoneGates`/doorways and the camera doesn't clip oddly at max size.

## Testing / Verification Plan

Manual playtesting in Studio via Rojo sync + MCP inspection (no unit test harness for Luau in this project), consistent with prior specs in this doc series:

1. Fresh player, Mass = 0: confirm stick-figure-thin body on spawn (~0.7x width/depth) and HUD shows `0` for both Coins and Mass in the top-right pill.
2. Eat a few times in Zone 1: confirm HUD numbers tick up with correct formatting, and confirm the body visibly widens with a smooth tween (not an instant pop).
3. Via MCP `execute_luau`, directly set a test player's `leaderstats.Mass` to a mid-range value (e.g. 500,000,000): confirm body scale sits at roughly the corresponding fraction of the way to the 20x cap, and the HUD displays the abbreviated form correctly (e.g. `500.0M`).
4. Set Mass to 1,000,000,000 or higher via MCP: confirm body scale hits exactly the 20x cap and does not exceed it even at much higher Mass values.
5. Die/respawn at high Mass: confirm the character respawns already at the correct large size instantly, with no skinny pop-in before re-growing.
6. Rejoin as a returning high-Mass player (simulated via MCP-set profile + rejoin): confirm correct size is applied instantly on first spawn of the session, not tweened from skinny.
7. Rapidly trigger several Mass gains in quick succession: visually confirm a single smooth tween to the final target rather than jittery stacked tweens.
8. Two players in the same server with very different Mass values: confirm each player correctly sees the other's proportions (server-authoritative replication working as expected).
9. Manual physical sanity check at the 20x cap: walk through existing `Zone2Gate` and other geometry, check for camera clipping or getting stuck.
10. Check server/client console throughout for unexpected warnings or errors.
