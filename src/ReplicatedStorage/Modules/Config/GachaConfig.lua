-- GachaConfig.lua
-- Odds and item tables for "Snack Crates."
-- PLACEHOLDER VALUES — tune after playtesting. See CLAUDE.md > Open Decisions.

return {
	Rarities = {
		{ Name = "Common",    Weight = 60, Color = Color3.fromRGB(180, 180, 180) },
		{ Name = "Rare",      Weight = 25, Color = Color3.fromRGB(70, 140, 255) },
		{ Name = "Epic",      Weight = 10, Color = Color3.fromRGB(170, 70, 255) },
		{ Name = "Legendary", Weight = 4,  Color = Color3.fromRGB(255, 170, 0) },
		{ Name = "Mythic",    Weight = 1,  Color = Color3.fromRGB(255, 60, 60) },
	},

	PityThreshold = 50, -- guaranteed Rare+ every N pulls without one

	Crates = {
		Free = {
			Name = "Snack Crate",
			CurrencyCost = 1000, -- in Coins
			-- Odds pull from Rarities above
		},
		Premium = {
			Name = "Golden Snack Crate",
			RobuxProductId = nil, -- fill in once the Developer Product is created in Studio
			-- Better odds table — TODO once base odds are validated
		},
	},

	-- Item pools, keyed by rarity. Titles ship first (zero art dependency),
	-- Pets/Auras get filled in once assets exist.
	Titles = {
		Common = { "Snacker", "Hungry" },
		Rare = { "Big Eater" },
		Epic = { "Food Champion" },
		Legendary = { "Legendary Glutton" },
		Mythic = { "The Bottomless Pit" },
	},
	Pets = {},
	Auras = {},
}
