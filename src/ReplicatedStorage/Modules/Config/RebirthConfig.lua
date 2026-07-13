-- RebirthConfig.lua
-- PLACEHOLDER VALUES — formula not finalized. See CLAUDE.md > Open Decisions
-- (flat % per rebirth vs. curve).

return {
	-- Coin threshold required in the final unlocked zone to rebirth.
	-- Scales per rebirth count below.
	BaseThreshold = 1000000,
	ThresholdGrowth = 1.5, -- multiplier applied per rebirth (placeholder)

	-- Permanent multiplier granted per rebirth. Placeholder: flat +10% per rebirth.
	CoinMultiplierPerRebirth = 0.10,
}
