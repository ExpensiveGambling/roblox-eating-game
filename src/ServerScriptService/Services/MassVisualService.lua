-- MassVisualService.lua
-- Owns the Mass -> body-scale (BodyWidthScale/BodyDepthScale) visual mapping. Read-only against
-- leaderstats.Mass -- never mutates Coins/Mass or touches DataStore. No other script sets
-- BodyWidthScale/BodyDepthScale.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local MassVisualConfig = require(ReplicatedStorage.Modules.Config.MassVisualConfig)

local MassVisualService = {}

-- Humanoid -> { Width = Tween, Depth = Tween }, weak-keyed so entries are GC'd when a Humanoid is
-- destroyed (respawn/leave).
local activeTweens = setmetatable({}, { __mode = "k" })

local function massToScale(mass)
	local t = math.clamp(mass / MassVisualConfig.MASS_AT_MAX_SCALE, 0, 1)
	local width = MassVisualConfig.MIN_WIDTH_SCALE
		+ (MassVisualConfig.MAX_WIDTH_SCALE - MassVisualConfig.MIN_WIDTH_SCALE) * t
	local depth = MassVisualConfig.MIN_DEPTH_SCALE
		+ (MassVisualConfig.MAX_DEPTH_SCALE - MassVisualConfig.MIN_DEPTH_SCALE) * t
	return width, depth
end

local function currentMass(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	local mass = leaderstats and leaderstats:FindFirstChild("Mass")
	return mass and mass.Value or 0
end

local function onCharacterAdded(player, character)
	local humanoid = character:WaitForChild("Humanoid")
	if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return
	end

	humanoid.AutomaticScalingEnabled = true

	local widthScale = humanoid:WaitForChild("BodyWidthScale", 5)
	local depthScale = humanoid:WaitForChild("BodyDepthScale", 5)
	if not widthScale or not depthScale then
		return
	end

	local width, depth = massToScale(currentMass(player))
	widthScale.Value = width
	depthScale.Value = depth
end

local function onMassChanged(player, newMass)
	local character = player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return
	end

	local widthScale = humanoid:FindFirstChild("BodyWidthScale")
	local depthScale = humanoid:FindFirstChild("BodyDepthScale")
	if not widthScale or not depthScale then
		return
	end

	local existing = activeTweens[humanoid]
	if existing then
		existing.Width:Cancel()
		existing.Depth:Cancel()
	end

	local width, depth = massToScale(newMass)
	local tweenInfo = TweenInfo.new(MassVisualConfig.TWEEN_TIME_SEC)
	local widthTween = TweenService:Create(widthScale, tweenInfo, { Value = width })
	local depthTween = TweenService:Create(depthScale, tweenInfo, { Value = depth })
	activeTweens[humanoid] = { Width = widthTween, Depth = depthTween }
	widthTween:Play()
	depthTween:Play()
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end

	task.spawn(function()
		local leaderstats = player:WaitForChild("leaderstats")
		local mass = leaderstats:WaitForChild("Mass")
		mass.Changed:Connect(function(newMass)
			onMassChanged(player, newMass)
		end)

		-- The character may have already spawned (and snapped using a stale/zero Mass reading)
		-- before leaderstats finished loading (e.g. slow DataStore GetAsync). Re-apply the
		-- now-known-correct scale so a returning high-Mass player is never left stuck skinny.
		if player.Character then
			onCharacterAdded(player, player.Character)
		end
	end)
end

function MassVisualService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return MassVisualService
