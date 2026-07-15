-- ZoneAccessService.lua
-- Owns per-player CollisionGroup wiring for zone-unlock walls. No other script registers
-- CollisionGroups or reads Workspace.ZoneGates.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZoneConfig = require(ReplicatedStorage.Modules.Config.ZoneConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)

local ZoneAccessService = {}

local WALL_GROUP_PREFIX = "ZoneWall_"
local PLAYER_GROUP_PREFIX = "Player_"

-- zoneId -> CollisionGroup name, populated by scanning Workspace.ZoneGates in Start().
local zoneWallGroups = {}

local function playerGroupName(player)
	return PLAYER_GROUP_PREFIX .. tostring(player.UserId)
end

local function wallGroupName(zoneId)
	return WALL_GROUP_PREFIX .. tostring(zoneId)
end

-- Scans Workspace.ZoneGates for BaseParts tagged with a ZoneId attribute, registers one
-- CollisionGroup per distinct ZoneId found, and assigns each wall Part to its group.
local function setUpZoneWallGroups()
	local zoneGates = workspace:FindFirstChild("ZoneGates")
	if not zoneGates then
		return
	end

	for _, wall in zoneGates:GetDescendants() do
		if wall:IsA("BasePart") then
			local zoneId = wall:GetAttribute("ZoneId")
			if zoneId then
				local groupName = wallGroupName(zoneId)
				if not zoneWallGroups[zoneId] then
					zoneWallGroups[zoneId] = groupName
					PhysicsService:RegisterCollisionGroup(groupName)
				end
				wall.CollisionGroup = groupName
			end
		end
	end
end

-- Sets this player's CollisionGroup collidability against every known zone wall group to match
-- their current UnlockedZones. Called on spawn/respawn.
local function syncPlayerCollision(player)
	local profile = PlayerDataService.Get(player)
	if not profile then
		return
	end

	local groupName = playerGroupName(player)
	for zoneId, wallGroup in zoneWallGroups do
		local unlocked = table.find(profile.UnlockedZones, zoneId) ~= nil
		PhysicsService:CollisionGroupSetCollidable(groupName, wallGroup, not unlocked)
	end
end

local function assignCharacterCollisionGroup(player, character)
	local groupName = playerGroupName(player)

	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = groupName
		end
	end

	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = groupName
		end
	end)
end

local function onCharacterAdded(player, character)
	assignCharacterCollisionGroup(player, character)
	syncPlayerCollision(player)
end

-- Waits for PlayerDataService profile to load (up to ~5 seconds with backoff),
-- then re-syncs collision if character is already present.
-- Used to handle the race condition where Character spawns before profile loads.
local function waitForProfileAndSync(player)
	local maxAttempts = 10
	local attemptCount = 0

	while attemptCount < maxAttempts do
		if not player.Parent then
			-- Player left the game
			return
		end

		local profile = PlayerDataService.Get(player)
		if profile then
			-- Profile is now available. If character exists, sync collision.
			if player.Character then
				syncPlayerCollision(player)
			end
			return
		end

		attemptCount = attemptCount + 1
		if attemptCount < maxAttempts then
			task.wait(0.5) -- Wait 0.5 seconds between attempts (~5 seconds total)
		end
	end
end

local function onPlayerAdded(player)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(playerGroupName(player))
	end)

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end

	-- Background retry: if profile loads after character spawn, re-sync collision.
	-- This fixes the race condition where Character spawns before PlayerDataService.Get completes.
	task.spawn(function()
		waitForProfileAndSync(player)
	end)
end

local function onPlayerRemoving(player)
	pcall(function()
		PhysicsService:UnregisterCollisionGroup(playerGroupName(player))
	end)
end

function ZoneAccessService.TryUnlockZone(player, zoneId)
	local zone = ZoneConfig[zoneId]
	if not zone then
		return false
	end

	local profile = PlayerDataService.Get(player)
	if not profile then
		return false
	end

	if table.find(profile.UnlockedZones, zoneId) then
		return false
	end

	if not table.find(profile.UnlockedZones, zoneId - 1) then
		return false
	end

	if not PlayerDataService.SpendCoins(player, zone.UnlockCost) then
		return false
	end

	PlayerDataService.UnlockZone(player, zoneId)

	local wallGroup = zoneWallGroups[zoneId]
	if wallGroup then
		PhysicsService:CollisionGroupSetCollidable(playerGroupName(player), wallGroup, false)
	end

	return true
end

local function onGatePromptTriggered(prompt, player)
	local gate = prompt.Parent
	if not gate then
		return
	end

	local zoneGates = workspace:FindFirstChild("ZoneGates")
	if not zoneGates or not gate:IsDescendantOf(zoneGates) then
		return
	end

	local zoneId = gate:GetAttribute("ZoneId")
	if not zoneId then
		return
	end

	ZoneAccessService.TryUnlockZone(player, zoneId)
end

-- Sets each gate prompt's display text from ZoneConfig, so balancing changes never require
-- re-editing the .model.json placeholder files.
local function setGatePromptText()
	local zoneGates = workspace:FindFirstChild("ZoneGates")
	if not zoneGates then
		return
	end

	for _, prompt in zoneGates:GetDescendants() do
		if prompt:IsA("ProximityPrompt") then
			local gate = prompt.Parent
			local zoneId = gate and gate:GetAttribute("ZoneId")
			local zone = zoneId and ZoneConfig[zoneId]
			if zone then
				prompt.ObjectText = zone.Name
				prompt.ActionText = ("Unlock (%d Coins)"):format(zone.UnlockCost)
			end
		end
	end
end

function ZoneAccessService.Start()
	setUpZoneWallGroups()
	setGatePromptText()

	ProximityPromptService.PromptTriggered:Connect(onGatePromptTriggered)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return ZoneAccessService
