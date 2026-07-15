-- ZoneAccessService.lua
-- Owns per-player CollisionGroup wiring for zone-unlock walls. No other script registers
-- CollisionGroups or reads Workspace.ZoneGates.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
end

local function onPlayerRemoving(player)
	pcall(function()
		PhysicsService:UnregisterCollisionGroup(playerGroupName(player))
	end)
end

function ZoneAccessService.Start()
	setUpZoneWallGroups()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return ZoneAccessService
