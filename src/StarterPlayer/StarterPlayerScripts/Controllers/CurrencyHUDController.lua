-- CurrencyHUDController.lua
-- Builds and keeps the top-right Coins/Mass HUD in sync with the local player's leaderstats.
-- Read-only against leaderstats -- never requests or computes currency values itself.

local Players = game:GetService("Players")

local CurrencyHUDController = {}

local player = Players.LocalPlayer

local function insertCommas(digits)
	local left, num, right = digits:match("^([^%d]*%d)(%d*)(.-)$")
	return left .. num:reverse():gsub("(%d%d%d)", "%1,"):reverse() .. right
end

local function formatNumber(value, decimals)
	if value >= 1000000000 then
		return string.format("%.1fB", value / 1000000000)
	elseif value >= 1000000 then
		return string.format("%.1fM", value / 1000000)
	end

	local whole = math.floor(value)
	local wholeStr = insertCommas(tostring(whole))

	if decimals > 0 then
		local fracStr = string.format("%." .. decimals .. "f", value - whole)
		return wholeStr .. fracStr:sub(2)
	end

	return wholeStr
end

local function buildHUD()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "CurrencyHUD"
	screenGui.ResetOnSpawn = false

	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.AnchorPoint = Vector2.new(1, 0)
	pill.Position = UDim2.new(1, -12, 0, 12)
	pill.Size = UDim2.new(0, 150, 0, 60)
	pill.BackgroundColor3 = Color3.new(0, 0, 0)
	pill.BackgroundTransparency = 0.45
	pill.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = pill

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.Padding = UDim.new(0, 2)
	layout.Parent = pill

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = pill

	local coinsLabel = Instance.new("TextLabel")
	coinsLabel.Name = "CoinsLabel"
	coinsLabel.Size = UDim2.new(1, 0, 0, 24)
	coinsLabel.BackgroundTransparency = 1
	coinsLabel.TextColor3 = Color3.new(1, 1, 1)
	coinsLabel.TextXAlignment = Enum.TextXAlignment.Right
	coinsLabel.Font = Enum.Font.GothamBold
	coinsLabel.TextSize = 18
	coinsLabel.Text = "Coins: 0"
	coinsLabel.Parent = pill

	local massLabel = Instance.new("TextLabel")
	massLabel.Name = "MassLabel"
	massLabel.Size = UDim2.new(1, 0, 0, 24)
	massLabel.BackgroundTransparency = 1
	massLabel.TextColor3 = Color3.new(1, 1, 1)
	massLabel.TextXAlignment = Enum.TextXAlignment.Right
	massLabel.Font = Enum.Font.GothamBold
	massLabel.TextSize = 18
	massLabel.Text = "Mass: 0.0"
	massLabel.Parent = pill

	screenGui.Parent = player:WaitForChild("PlayerGui")

	return coinsLabel, massLabel
end

function CurrencyHUDController.Start()
	local coinsLabel, massLabel = buildHUD()

	local leaderstats = player:WaitForChild("leaderstats")
	local coins = leaderstats:WaitForChild("Coins")
	local mass = leaderstats:WaitForChild("Mass")

	local function updateCoins()
		coinsLabel.Text = "Coins: " .. formatNumber(coins.Value, 0)
	end

	local function updateMass()
		massLabel.Text = "Mass: " .. formatNumber(mass.Value, 1)
	end

	coins.Changed:Connect(updateCoins)
	mass.Changed:Connect(updateMass)

	updateCoins()
	updateMass()
end

return CurrencyHUDController
