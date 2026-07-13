-- EconomyService.lua
-- Sole owner of Coin/Mass grants. No other script mutates these values directly.
-- All grants must be server-triggered and validated against ZoneConfig — never trust
-- a client-sent currency amount.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZoneConfig = require(ReplicatedStorage.Modules.Config.ZoneConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)

local EconomyService = {}

function EconomyService.GrantEatReward(player, zoneId)
	local zone = ZoneConfig[zoneId]
	if not zone then
		return
	end

	PlayerDataService.AddCoins(player, zone.CoinsPerBite)
	PlayerDataService.AddMass(player, zone.MassPerBite)
end

function EconomyService.Start() end

return EconomyService
