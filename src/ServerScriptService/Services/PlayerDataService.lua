-- PlayerDataService.lua
-- Sole owner of the in-memory PlayerProfile cache and leaderstats.
-- No other script reads/writes the cache or leaderstats directly.
-- Persistence (real DataStore save/load) is deferred; only this module will change when it's added.

local Players = game:GetService("Players")

local PlayerDataService = {}

local DEFAULT_PROFILE = {
	Version = 1,
	Coins = 0,
	Mass = 0,
	RebirthCount = 0,
	UnlockedZones = { 1 },
	OwnedPets = {},
	EquippedPet = nil,
	OwnedAuras = {},
	EquippedAura = nil,
	OwnedTitles = {},
	EquippedTitle = nil,
	GamepassCache = {},
}

local Cache = {}

local function copyDefaultProfile()
	local profile = {}
	for key, value in DEFAULT_PROFILE do
		if type(value) == "table" then
			profile[key] = table.clone(value)
		else
			profile[key] = value
		end
	end
	return profile
end

local function createLeaderstats(player, profile)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = profile.Coins
	coins.Parent = leaderstats

	local mass = Instance.new("NumberValue")
	mass.Name = "Mass"
	mass.Value = profile.Mass
	mass.Parent = leaderstats

	leaderstats.Parent = player
end

local function onPlayerAdded(player)
	local profile = copyDefaultProfile()
	Cache[player.UserId] = profile
	createLeaderstats(player, profile)
end

local function onPlayerRemoving(player)
	-- TODO: flush profile to DataStore here once PlayerDataService owns real persistence.
	Cache[player.UserId] = nil
end

function PlayerDataService.Get(player)
	return Cache[player.UserId]
end

function PlayerDataService.AddCoins(player, amount)
	local profile = Cache[player.UserId]
	if not profile then
		return
	end
	profile.Coins += amount
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		leaderstats.Coins.Value = profile.Coins
	end
end

function PlayerDataService.AddMass(player, amount)
	local profile = Cache[player.UserId]
	if not profile then
		return
	end
	profile.Mass += amount
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		leaderstats.Mass.Value = profile.Mass
	end
end

function PlayerDataService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return PlayerDataService
