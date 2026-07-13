-- ZoneConfig.lua
-- Single source of truth for zone/food-tier balancing.
-- EconomyService reads from this; never hardcode these numbers in logic scripts.

return {
	[1] = {
		Name = "Garden",
		FoodTheme = { "Broccoli", "Carrot", "Salad" },
		CoinsPerBite = 1,
		MassPerBite = 0.1,
		UnlockCost = 0,
	},
	[2] = {
		Name = "Kitchen",
		FoodTheme = { "Sandwich", "Rice", "Chicken" },
		CoinsPerBite = 5,
		MassPerBite = 0.5,
		UnlockCost = 500,
	},
	[3] = {
		Name = "Fast Food",
		FoodTheme = { "Pizza", "Burger", "Fries" },
		CoinsPerBite = 25,
		MassPerBite = 2,
		UnlockCost = 5000,
	},
	[4] = {
		Name = "Dessert Bar",
		FoodTheme = { "Cake", "Donut", "Candy" },
		CoinsPerBite = 100,
		MassPerBite = 8,
		UnlockCost = 50000,
	},
	[5] = {
		Name = "Absurd Tier",
		FoodTheme = { "Whole Turkey", "Gallon Jug", "The Entire Fridge" },
		CoinsPerBite = 500,
		MassPerBite = 30,
		UnlockCost = 500000,
	},
}
