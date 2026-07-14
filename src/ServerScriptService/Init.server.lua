-- Init.server.lua
-- Boot sequence: requires and starts every Service, in dependency order.
-- Also assigns ZoneId attributes to placeholder world objects programmatically, since Rojo's
-- .model.json format does not apply Attributes from the JSON file in this project's environment
-- (confirmed during Task 1 — see the design spec's Amendment section for full detail).

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Services = ServerScriptService.Services

local PlayerDataService = require(Services.PlayerDataService)
local EconomyService = require(Services.EconomyService)
local FoodService = require(Services.FoodService)

local function assignZoneAttributes()
	workspace.FoodTables.Zone1Table:SetAttribute("ZoneId", 1)
	ReplicatedStorage.Assets.FoodTools.Broccoli:SetAttribute("ZoneId", 1)

	workspace.FoodTables.Zone2Table:SetAttribute("ZoneId", 2)
	ReplicatedStorage.Assets.FoodTools.Sandwich:SetAttribute("ZoneId", 2)

	for _, wall in workspace.ZoneGates.Zone2Gate:GetChildren() do
		if wall:IsA("BasePart") then
			wall:SetAttribute("ZoneId", 2)
		end
	end
end

assignZoneAttributes()

PlayerDataService.Start()
EconomyService.Start()
FoodService.Start()
