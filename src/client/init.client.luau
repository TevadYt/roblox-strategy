--!strict
-- Client entry point. Shows the player's resources, read from the attributes
-- ResourceService sets on the Player, then starts the board camera.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local player = Players.LocalPlayer

local gui = Instance.new("ScreenGui")
gui.Name = "ResourceHud"
gui.ResetOnSpawn = false

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0)
frame.Position = UDim2.new(0.5, 0, 0, 8)
frame.Size = UDim2.fromOffset(0, 32)
frame.AutomaticSize = Enum.AutomaticSize.X
frame.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
frame.BackgroundTransparency = 0.25
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = frame

local padding = Instance.new("UIPadding")
padding.PaddingLeft = UDim.new(0, 12)
padding.PaddingRight = UDim.new(0, 12)
padding.Parent = frame

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.Padding = UDim.new(0, 16)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.VerticalAlignment = Enum.VerticalAlignment.Center
layout.Parent = frame

for index, resource in GameConfig.Resources do
	local label = Instance.new("TextLabel")
	label.Name = resource
	label.LayoutOrder = index
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = frame

	local attribute = "Resource_" .. resource
	local function refresh()
		label.Text = `{resource}: {player:GetAttribute(attribute) or 0}`
	end
	player:GetAttributeChangedSignal(attribute):Connect(refresh)
	refresh()
end

gui.Parent = player:WaitForChild("PlayerGui")

require(script.MapCamera).start()
