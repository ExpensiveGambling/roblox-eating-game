# Zone Unlock Gating — Design Spec

Date: 2026-07-14
Status: Approved for planning

## Purpose

Implement real zone-unlock gating: players must pay coins at a physical gate to access Zone 2+, and
until they do, they are physically blocked from entering. This is a scoped-down version of Phase 3 in
`CLAUDE.md`'s build order — the multi-food-per-zone work originally bundled into Phase 3 is explicitly
deferred (see Out of Scope). Zone 1 remains free/always-unlocked per `DEFAULT_PROFILE.UnlockedZones = {1}`.

## Out of Scope (explicitly deferred)

- **Multiple food types per zone.** `FoodService.getFoodToolTemplate` still hardcodes `zone.FoodTheme[1]`.
  Zone 2 gets exactly one food item (Sandwich), matching Zone 1's one-food (Broccoli) pattern. Revisit
  per the existing note in `project_food_pickup_loop_status` memory.
- **Zones 3-5 physical assets.** Only Zone 2's gate + table are built now, to prove the pattern
  end-to-end. Zones 3-5 are asset/config swaps of this same pattern, deferred to the "Zones 2-5" build
  phase per `CLAUDE.md`.
- **Custom UI feedback for failed purchases** (e.g. "not enough coins" toast). Rejected in favor of
  relying on the `ProximityPrompt`'s built-in text to show cost — explicit user decision to keep this
  phase's scope small; no new UI component or remote round-trip.
- **VIP zone early access gamepass.** Mentioned in `CLAUDE.md`'s monetization section but not part of
  this phase — the gating built here is the mechanism a future gamepass would hook into (bypass the
  coin cost, not the sequential-unlock check), not something wired up now.

## Architecture

**New service:** `src/ServerScriptService/Services/ZoneAccessService.lua`, owning:
1. Per-player `CollisionGroup` registration/assignment (join, respawn, leave).
2. Per-zone `CollisionGroup` collidability sync against that player's `UnlockedZones`.
3. The unlock-gate `ProximityPrompt` purchase handler.

**Two new `PlayerDataService` methods**, added alongside the existing `AddCoins`/`AddMass` (same
style: look up `Cache[player.UserId]`, mutate, return):
- `SpendCoins(player, amount): boolean` — atomic check-and-deduct (`profile.Coins >= amount`), returns
  whether it succeeded. Non-yielding Luau code between check and deduct, so no race window.
- `UnlockZone(player, zoneId)` — appends `zoneId` to `profile.UnlockedZones` if not already present.

**Per-player wall passability via CollisionGroups** (the standard Roblox simulator-genre pattern, per
your explicit choice): each locked zone is surrounded by an invisible box of wall `Part`s, all in a
`CollisionGroup` named `ZoneWall_<ZoneId>`. Each player gets their own `CollisionGroup`
(`Player_<UserId>`) assigned to every `BasePart` of their character. `ZoneAccessService` sets
`PhysicsService:CollisionGroupSetCollidable(playerGroup, "ZoneWall_<N>", collidable)` per zone per
player, where `collidable = not table.find(profile.UnlockedZones, N)`. This makes the same physical
wall solid for one player and passable for another in the same server.

**Unlock purchase flow** — native `ProximityPrompt`, no `RemoteEvent` (matches the existing food-pickup
pattern; this project doesn't use the `RemoteNames.lua` convention from the unrelated Spotlight
project):
1. Player holds the gate's prompt → `ProximityPromptService.PromptTriggered` fires server-side.
2. Handler reads `ZoneId` off the prompt's parent, looks up `UnlockCost` from `ZoneConfig`.
3. Guards, in order, fail-closed (silent no-op on any failure, no client feedback):
   - Zone must not already be in `UnlockedZones` (prevents double-charge on re-trigger).
   - `zoneId - 1` must already be in `UnlockedZones` (sequential unlock — per `CLAUDE.md`'s gamepass
     note "VIP zone early access... not zone-skip exploits", implying unlock order is enforced).
   - `PlayerDataService.SpendCoins(player, cost)` must return `true`.
4. On success: `PlayerDataService.UnlockZone(player, zoneId)`, then flip that player's collision pair
   for `ZoneWall_<zoneId>` to non-collidable.

**Defense in depth in `FoodService`:** `onPromptTriggered` gains an `UnlockedZones` check (via
`PlayerDataService.Get(player).UnlockedZones`) before calling `GivePlayerFood`, even though the wall
should already prevent physical entry — guards against noclip/teleport exploits bypassing collision,
per this project's fail-closed security rule.

## Data Flow

1. **Join / respawn** (`Players.PlayerAdded` → `CharacterAdded`):
   - Register `Player_<UserId>` collision group if not already registered (join only).
   - Assign every character `BasePart` to that group (every `CharacterAdded`, since respawn creates a
     fresh character with parts back on the `Default` group).
   - For each zone `N` in `ZoneConfig` beyond Zone 1, read the just-loaded profile's `UnlockedZones`
     and set `CollisionGroupSetCollidable(playerGroup, "ZoneWall_<N>", not unlocked)`.
2. **Gate interaction:** see Unlock purchase flow above. Runs entirely server-side, no client input
   trusted beyond "this player triggered this prompt."
3. **Leave:** `PhysicsService:UnregisterCollisionGroup("Player_<UserId>")` to avoid leaking groups over
   a long-running server. Runs after `PlayerDataService`'s own `PlayerRemoving` save (ordering doesn't
   matter functionally, but keep it in `ZoneAccessService`'s own `PlayerRemoving` connection to avoid
   cross-service coupling).

## Component Details

### `ZoneAccessService.lua` (new)
- `Start()`: connects `Players.PlayerAdded`/`CharacterAdded`/`PlayerRemoving`, iterates existing
  players (mirrors `PlayerDataService.Start`'s late-boot pattern), scans `Workspace.ZoneGates` for wall
  Parts tagged with a `ZoneId` attribute and registers one `CollisionGroup` per distinct `ZoneId`
  found, wires `ProximityPromptService.PromptTriggered` for gate prompts (identified by the prompt's
  parent having a `ZoneId` attribute *and* being under `Workspace.ZoneGates`, to disambiguate from food
  table prompts which live under `Workspace.FoodTables`).
- `syncPlayerCollision(player, profile)`: local helper, loops registered zone wall groups, sets
  collidability per the formula above.
- `onGatePromptTriggered(prompt, player)`: implements the 4-step guarded purchase flow above.

### `PlayerDataService.lua` (modified)
- Add `SpendCoins(player, amount): boolean` and `UnlockZone(player, zoneId)` next to `AddCoins`/`AddMass`.
- No changes to `DEFAULT_PROFILE`, load/save paths, or the public `Get` accessor.

### `FoodService.lua` (modified)
- In `onPromptTriggered`, after resolving `zoneId` and before calling `FoodService.GivePlayerFood`,
  check `table.find(PlayerDataService.Get(player).UnlockedZones, zoneId)`; return early (silent) if
  not found.
- Requires adding a `require(script.Parent.PlayerDataService)` to `FoodService.lua` (currently only
  `EconomyService` is required there).

### `Init.server.lua` (modified)
- Add `ZoneAccessService` to the boot sequence, after `PlayerDataService` (needs the loaded cache to
  seed initial collision state) and before `FoodService` (no hard dependency, kept adjacent since both
  are zone-related).

### New Workspace/ReplicatedStorage assets
- `src/Workspace/ZoneGates/Zone2Gate.model.json` — wall `Part`s forming a box around the Zone 2 area,
  each tagged with `ZoneId = 2` (attribute), all `CanCollide = true`; one wall-facing `Part` holds the
  `ProximityPrompt` (`ObjectText`/`ActionText` set server-side from `ZoneConfig[2].Name`/`UnlockCost`
  in `ZoneAccessService.Start()`, so config changes don't require re-editing the model).
- `src/Workspace/FoodTables/Zone2Table.model.json` — mirrors `Zone1Table.model.json`, tagged
  `ZoneId = 2`.
- `src/ReplicatedStorage/Assets/FoodTools/Sandwich.model.json` — mirrors `Broccoli.model.json`.

## Error Handling

- **DataStore load race:** `ZoneAccessService`'s spawn-time sync only reads `PlayerDataService.Get`,
  never touches DataStore directly, and only runs after `PlayerDataService.onPlayerAdded` has already
  either populated the cache or kicked the player — no new race introduced.
- **Double-trigger / spam-clicking the gate prompt:** guarded by the "already unlocked" check (guard 1
  in the purchase flow) — a re-trigger after a successful unlock silently no-ops instead of
  double-charging.
- **Sequential-unlock skip:** guarded by the "previous zone unlocked" check (guard 2) — same
  fail-closed, silent-drop pattern used elsewhere in this codebase (e.g. `FoodService`'s cooldown
  check).
- **Collision group cap:** per-player groups are unregistered on `PlayerRemoving`, keeping steady-state
  registered-group count bounded to concurrent player count plus the small fixed number of zone-wall
  groups — well under Roblox's practical limits for this game's expected server sizes.
- **Server shutdown mid-purchase:** no special handling needed. `UnlockZone`/`SpendCoins` mutate the
  same in-memory `Cache` that `AddCoins`/`AddMass` already mutate, so it rides the existing
  save-on-leave/save-on-shutdown path with no new failure mode.
- **Respawn:** collision group re-assignment on every `CharacterAdded` (not just once per session)
  handles the fresh-character-defaults-to-`Default`-group case.

## Testing / Verification Plan

Manual playtesting in Studio via Rojo sync + MCP inspection (no unit test harness for Luau in this
project):

1. Fresh player, 0 coins: confirm bouncing off the Zone 2 wall; confirm the unlock prompt is visible
   but triggering it does nothing (can't afford it).
2. Grant enough coins (MCP live-edit, test-only, not part of persisted game logic) → trigger the
   prompt → confirm coins deduct, confirm the wall is now passable, confirm the Sandwich tool can be
   picked up and eaten for the correct Coins/Mass per `ZoneConfig[2]`.
3. Re-trigger the (now-passable) gate's prompt → confirm no additional coins are deducted.
4. Attempt a Zone 3+ unlock directly via MCP `execute_luau` (simulating a skip exploit) while only Zone
   1 is unlocked → confirm rejection.
5. Unlock Zone 2, die/respawn → confirm the wall is still passable post-respawn.
6. Unlock Zone 2, leave, rejoin → confirm the wall is passable immediately on the new spawn.
7. Two players in one server, only one with Zone 2 unlocked → confirm the other still bounces off the
   same physical wall (the core property the `CollisionGroup` design exists to prove).
8. With Zone 2 locked, trigger the Zone 2 food `ProximityPrompt` directly via MCP (bypassing the wall)
   → confirm `FoodService` still grants nothing.
9. Check server console throughout for unexpected warnings/errors.
