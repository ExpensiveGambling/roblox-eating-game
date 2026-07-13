-- LeaderboardService.lua
-- Owns the OrderedDataStore leaderboard (kept separate from PlayerDataService's
-- DataStore intentionally). Sort key TBD — see CLAUDE.md > Open Decisions.
-- Refresh on an interval, not per-frame, to stay under DataStore request limits.

return {}
