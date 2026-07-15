-- GameplayConfig.lua
-- Non-zone-specific gameplay tunables. Never hardcode these values in logic scripts.

return {
	EAT_COOLDOWN_SEC = 1, -- placeholder until a real eat animation exists; retune to match its length
	MAX_PLAYERS = 26, -- caps concurrent players to stay under Roblox's hard 32-CollisionGroup limit
	                   -- (1 Default + up to 26 players + up to 4 gated zones [Zones 2-5])
}
