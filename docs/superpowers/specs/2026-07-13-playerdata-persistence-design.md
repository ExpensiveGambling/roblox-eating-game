# PlayerDataService — DataStore Persistence — Design Spec

Date: 2026-07-13
Status: Approved for planning

## Purpose

Replace `PlayerDataService`'s current in-memory-only cache with real `DataStoreService` persistence,
so a player's Coins/Mass/etc. survive leaving and rejoining. This is Phase 2 of `CLAUDE.md`'s build
order, deferred intentionally during the food pickup/eat loop (Phase 1) — see that phase's design doc
(`2026-07-12-food-pickup-eat-loop-design.md`) and its `-- TODO: flush profile to DataStore here`
marker in `PlayerDataService.lua`.

No other file changes. `PlayerDataService`'s public interface (`Get`, `AddCoins`, `AddMass`, `Start`)
stays identical, so `EconomyService.lua`, `FoodService.lua`, and anything else that reads/writes
player currency needs zero changes.

## Out of Scope (explicitly deferred)

- **Periodic autosave.** Save-on-leave + save-on-shutdown only, per explicit user decision — "no need
  to overcomplicate the system at this stage." Revisit only if server crashes (not clean shutdowns)
  turn out to be a real source of lost progress.
- **Session-locking library (ProfileService/ProfileStore).** Rejected in favor of plain
  `DataStoreService` + `UpdateAsync`, per explicit user decision after weighing the tradeoff (see
  Architecture below for the accepted risk this leaves open).
- **Schema migration logic.** `PlayerProfile.Version` already exists in the schema for this purpose,
  but no migration code is written now since no schema version bump has happened yet. When one is
  needed, it slots into the load path's merge step.
- **"Let them play unsaved" fallback on load failure.** Explicitly rejected — see Error Handling.

## Architecture

Only `src/ServerScriptService/Services/PlayerDataService.lua` changes. The in-memory `Cache` table
remains the single source of truth *while a player is in the server* — DataStore is only touched at
session boundaries (join, leave, shutdown), never on every `AddCoins`/`AddMass` call. This keeps the
hot path (every food bite) free of any DataStore latency.

**Storage:**
- DataStore name: `PlayerData_v1` (bump the numeric suffix on any breaking schema change rather than
  mutating existing saved data in place).
- Key format: `Player_<UserId>`.
- `UpdateAsync` (not `SetAsync`) for all writes, per `CLAUDE.md`'s non-negotiable rule, so a save can't
  blindly clobber a value written by another server since the read.

**Accepted risk:** without session-locking, a player who rejoins a *different* server within seconds
of leaving one has a small chance of a stale overwrite (the old server's shutdown-save racing the new
server's join-load). This was an explicit, informed tradeoff during brainstorming given the project
has no real players yet and prioritizes low complexity at this stage. Revisit if it ever causes an
actual reported issue.

## Data Flow

1. **Join** (`Players.PlayerAdded`):
   - Call `GetAsync("Player_<UserId>")`, pcall-wrapped, retried up to 3 times with 1s/2s/4s backoff
     between attempts.
   - If the key doesn't exist (new player): use `DEFAULT_PROFILE` as-is.
   - If the key exists: merge the loaded table over `DEFAULT_PROFILE` (defaults fill in any field
     missing from the saved data — e.g. a schema field added after that player's last save — but never
     overwrite a value the save actually has).
   - If all 3 attempts error: kick the player (`Player:Kick("...")`) with a plain-language message,
     and `warn(...)` to the server console including the player's name and UserId so it's diagnosable
     without needing to reproduce it live.
2. **Gameplay:** unchanged. `AddCoins`/`AddMass` mutate `Cache[UserId]` and the mirrored `leaderstats`
   values only — no DataStore call on this path.
3. **Leave** (`Players.PlayerRemoving`):
   - `UpdateAsync("Player_<UserId>", ...)` with the current cached profile, pcall-wrapped, retried up
     to 3 times with 1s/2s/4s backoff.
   - If all attempts fail: `warn(...)` to the server console with player name/UserId and the error —
     nothing else to do, the player is already gone.
   - Clear `Cache[UserId]` after the save attempt (success or not) to avoid a memory leak.
4. **Shutdown** (`game:BindToClose()`):
   - For every player still in `Cache`, kick off a save concurrently (e.g. one `task.spawn` per
     player) rather than sequentially, so total shutdown time is roughly one save's worth of latency,
     not N.
   - Each save uses a shorter retry budget than the leave/join path (single attempt, no multi-second
     backoff) so the whole batch finishes comfortably inside Roblox's shutdown grace window.
   - Wait for all spawned saves to finish (or a hard ceiling, e.g. 25s) before returning from
     `BindToClose`.

## Component Details

### `PlayerDataService.lua`
- `DEFAULT_PROFILE` and its `copyDefaultProfile()` helper: unchanged.
- New local helpers:
  - `loadProfile(userId): (profile, success)` — wraps `GetAsync` in the pcall+retry policy above,
    returns the merged profile and whether the load succeeded (vs. exhausted retries).
  - `saveProfile(userId, profile, retryBudget)` — wraps `UpdateAsync` in pcall+retry, `retryBudget`
    lets the shutdown path use a shorter budget than the leave path without duplicating the retry
    loop.
  - `mergeWithDefaults(saved): profile` — shallow-merges `saved` over a fresh
    `copyDefaultProfile()`, field by field, so missing keys get defaults without discarding present
    ones.
- `onPlayerAdded(player)`: calls `loadProfile`; on failure, `player:Kick(...)` and returns early
  (no `Cache` entry, no `leaderstats` created) instead of the current unconditional
  `copyDefaultProfile()`.
- `onPlayerRemoving(player)`: calls `saveProfile` with the full retry budget, then clears `Cache`.
- `Start()`: adds a `game:BindToClose(onShutdown)` connection alongside the existing
  `PlayerAdded`/`PlayerRemoving` connections.
- `Get`, `AddCoins`, `AddMass`: unchanged.

## Error Handling

- Every DataStore call (`GetAsync`, `UpdateAsync`) is pcall-wrapped; a thrown error is caught, logged,
  and treated as a retry-able failure — never propagates and crashes the calling connection.
- **Load failure (all retries exhausted):** kick with a plain-language message
  (e.g. `"Couldn't load your save data — please try rejoining."`) — chosen over letting the player
  play unsaved, so nobody has a session where progress is silently discarded. This was an explicit
  design decision during brainstorming (see that section's discussion of the kick-loop concern): each
  join's retry sequence is independent, so this can't cascade into a persistent loop from our own
  code — a repeated failure would mean either a genuine ongoing Roblox-side DataStore outage
  (unfixable on our end, same as any other game) or a bug in this file's own logic, which testing
  before shipping is meant to catch.
- **Save failure (all retries exhausted), on leave or shutdown:** log only, no further action —
  there's no user-facing recovery possible at that point.

## Testing / Verification Plan

Since this project has no published place or real player data yet, testing happens directly in the
current dev place:

1. Enable "Studio Access to API Services" in this place's Game Settings → Security (one-time, done by
   the user in Studio, not scriptable).
2. Start Play mode, walk to the Zone 1 table, eat Broccoli a few times to accrue nonzero Coins/Mass.
3. Stop Play mode (triggers `PlayerRemoving`), restart Play mode, confirm the same player's
   `leaderstats.Coins`/`Mass` reload with the previously-earned values instead of resetting to 0.
4. Confirm a brand-new UserId (or a player who has never saved before) still gets
   `DEFAULT_PROFILE` values with no errors.
5. If feasible in Studio, exercise the `BindToClose` path (e.g. stopping the server while a player is
   present) and confirm the save still lands.
6. Check the server console throughout for unexpected warnings/errors.
