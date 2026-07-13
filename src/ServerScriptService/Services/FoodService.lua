-- FoodService.lua
-- Owns food pickup (ProximityPrompt) and eat (Tool.Activated) wiring.
-- Both signals fire server-side natively — no custom RemoteEvents needed here.
-- Currency math is never done in this file; it always delegates to EconomyService.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZoneConfig = require(ReplicatedStorage.Modules.Config.ZoneConfig)
local GameplayConfig = require(ReplicatedStorage.Modules.Config.GameplayConfig)
local EconomyService = require(script.Parent.EconomyService)

local FoodService = {}

local lastEatTime = {}

local function getFoodToolTemplate(zoneId)
	local zone = ZoneConfig[zoneId]
	if not zone then
		return nil
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local toolsFolder = assets and assets:FindFirstChild("FoodTools")
	if not toolsFolder then
		return nil
	end

	return toolsFolder:FindFirstChild(zone.FoodTheme[1])
end

local function removeExistingFoodTool(player)
	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		for _, item in backpack:GetChildren() do
			if item:IsA("Tool") and item:GetAttribute("ZoneId") ~= nil then
				item:Destroy()
			end
		end
	end

	local character = player.Character
	if character then
		for _, item in character:GetChildren() do
			if item:IsA("Tool") and item:GetAttribute("ZoneId") ~= nil then
				item:Destroy()
			end
		end
	end
end

function FoodService.HandleEatAttempt(player, tool)
	local zoneId = tool:GetAttribute("ZoneId")
	if not zoneId then
		return
	end

	local now = os.clock()
	local last = lastEatTime[player.UserId]
	if last and now - last < GameplayConfig.EAT_COOLDOWN_SEC then
		return
	end
	lastEatTime[player.UserId] = now

	EconomyService.GrantEatReward(player, zoneId)
end

function FoodService.GivePlayerFood(player, zoneId)
	local template = getFoodToolTemplate(zoneId)
	if not template then
		return
	end

	local backpack = player:FindFirstChild("Backpack")
	if not backpack then
		return
	end

	removeExistingFoodTool(player)

	local tool = template:Clone()
	tool.Parent = backpack

	tool.Activated:Connect(function()
		FoodService.HandleEatAttempt(player, tool)
	end)
end

local function onPromptTriggered(prompt, player)
	local tableInstance = prompt.Parent
	if not tableInstance then
		return
	end

	local zoneId = tableInstance:GetAttribute("ZoneId")
	if not zoneId then
		return
	end

	FoodService.GivePlayerFood(player, zoneId)
end

local function onPlayerRemoving(player)
	lastEatTime[player.UserId] = nil
end

function FoodService.Start()
	ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return FoodService
