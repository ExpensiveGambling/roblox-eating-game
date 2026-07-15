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
