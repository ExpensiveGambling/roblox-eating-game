-- PlayerDataService.lua
-- Sole owner of the in-memory PlayerProfile cache, leaderstats, and DataStore persistence.
-- No other script reads/writes the cache, leaderstats, or the DataStore directly.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local PlayerDataService = {}

local DATASTORE_NAME = "PlayerData_v1"
local KEY_PREFIX = "Player_"

local LOAD_SAVE_RETRY_COUNT = 3
local LOAD_SAVE_RETRY_BACKOFF_SEC = { 1, 2, 4 }
local SHUTDOWN_RETRY_COUNT = 1
local SHUTDOWN_TIMEOUT_SEC = 25

local PlayerDataStore = DataStoreService:GetDataStore(DATASTORE_NAME)

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

local function mergeWithDefaults(saved)
	local profile = copyDefaultProfile()
	for key in DEFAULT_PROFILE do
		if saved[key] ~= nil then
			profile[key] = saved[key]
		end
	end
	return profile
end

local function profileKey(userId)
	return KEY_PREFIX .. tostring(userId)
end

-- Returns (profile, success). success is false only after every retry attempt errored.
local function loadProfile(userId)
	local key = profileKey(userId)

	for attempt = 1, LOAD_SAVE_RETRY_COUNT do
		local ok, result = pcall(function()
			return PlayerDataStore:GetAsync(key)
		end)

		if ok then
			if result == nil then
				return copyDefaultProfile(), true
			end
			return mergeWithDefaults(result), true
		end

		warn(
			("[PlayerDataService] GetAsync failed for %s (attempt %d/%d): %s"):format(
				key,
				attempt,
				LOAD_SAVE_RETRY_COUNT,
				tostring(result)
			)
		)

		if attempt < LOAD_SAVE_RETRY_COUNT then
			task.wait(LOAD_SAVE_RETRY_BACKOFF_SEC[attempt])
		end
	end

	return nil, false
end

-- Returns success. backoffSeconds may be nil to retry with no delay between attempts.
local function saveProfile(userId, profile, retryCount, backoffSeconds)
	local key = profileKey(userId)

	for attempt = 1, retryCount do
		local ok, err = pcall(function()
			PlayerDataStore:UpdateAsync(key, function()
				return profile
			end)
		end)

		if ok then
			return true
		end

		warn(
			("[PlayerDataService] UpdateAsync failed for %s (attempt %d/%d): %s"):format(
				key,
				attempt,
				retryCount,
				tostring(err)
			)
		)

		if backoffSeconds and attempt < retryCount then
			task.wait(backoffSeconds[attempt])
		end
	end

	return false
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
	local profile, success = loadProfile(player.UserId)

	if not success then
		warn(
			("[PlayerDataService] Failed to load save data for %s (%d) after retries — kicking."):format(
				player.Name,
				player.UserId
			)
		)
		player:Kick("Couldn't load your save data — please try rejoining.")
		return
	end

	Cache[player.UserId] = profile
	createLeaderstats(player, profile)
end

local function onPlayerRemoving(player)
	local profile = Cache[player.UserId]

	if profile then
		local success = saveProfile(player.UserId, profile, LOAD_SAVE_RETRY_COUNT, LOAD_SAVE_RETRY_BACKOFF_SEC)
		if not success then
			warn(
				("[PlayerDataService] Failed to save data for %s (%d) after retries — data may be lost."):format(
					player.Name,
					player.UserId
				)
			)
		end
	end

	if Cache[player.UserId] == profile then
		Cache[player.UserId] = nil
	end
end

local function onShutdown()
	local pending = 0

	for userId, profile in Cache do
		pending += 1
		task.spawn(function()
			local success = saveProfile(userId, profile, SHUTDOWN_RETRY_COUNT, nil)
			if not success then
				warn(("[PlayerDataService] Shutdown save failed for UserId %d"):format(userId))
			end
			pending -= 1
		end)
	end

	local deadline = os.clock() + SHUTDOWN_TIMEOUT_SEC
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
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
	game:BindToClose(onShutdown)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return PlayerDataService
