-- PlayerDataService.lua
-- Sole owner of DataStore reads/writes. No other script touches DataStore directly.
-- Schema: see CLAUDE.md > DataStore Schema.
-- Use UpdateAsync (not SetAsync) for incremented values. Wrap all calls in pcall with retry.

return {}
