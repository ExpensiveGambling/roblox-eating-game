-- Init.server.lua
-- Boot sequence: requires and starts every Service, in dependency order.
-- Also assigns ZoneId attributes to placeholder world objects programmatically, since Rojo's
-- .model.json format does not apply Attributes from the JSON file in this project's environment
-- (confirmed during Task 1 — see the design spec's Amendment section for full detail).

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Services = ServerScriptService.Services
local GameplayConfig = require(ReplicatedStorage.Modules.Config.GameplayConfig)

local PlayerDataService = require(Services.PlayerDataService)
local MassVisualService = require(Services.MassVisualService)
local ZoneAccessService = require(Services.ZoneAccessService)
local EconomyService = require(Services.EconomyService)
local FoodService = require(Services.FoodService)

-- Enforce player cap to stay under Roblox's 32-CollisionGroup-per-place limit
-- (1 Default + up to 26 players + up to 4 gated zones [Zones 2-5])
-- Players beyond MAX_PLAYERS are kicked before any Service processes them.
local function enforcePlayerCap(player)
	if #Players:GetPlayers() > GameplayConfig.MAX_PLAYERS then
		player:Kick("Server is full — please try another server.")
	end
end

Players.PlayerAdded:Connect(enforcePlayerCap)

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
MassVisualService.Start()
ZoneAccessService.Start()
EconomyService.Start()
FoodService.Start()
