--!strict
-- Two panels: a player list (seat color, name, territories and armies held)
-- on the left, and details of the selected territory at the bottom. Both
-- are rebuilt from the replicated state whenever it changes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Territories = require(ReplicatedStorage.Shared.Territories)
local TerritorySelection = require(script.Parent.TerritorySelection)

local TerritoryHud = {}

local BACKGROUND = Color3.fromRGB(20, 20, 24)

local function panel(name: string, parent: Instance): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = BACKGROUND
	frame.BackgroundTransparency = 0.25
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	return frame
end

local function text(parent: Instance, order: number, size: number, bold: boolean): TextLabel
	local label = Instance.new("TextLabel")
	label.LayoutOrder = order
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.new()
	label.BackgroundTransparency = 1
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextSize = size
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end

local function playerRow(parent: Instance, order: number, player: Player, held: number, armies: number)
	local row = Instance.new("Frame")
	row.LayoutOrder = order
	row.BackgroundTransparency = 1
	row.AutomaticSize = Enum.AutomaticSize.XY
	row.Size = UDim2.new()
	row.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 8)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	local swatch = Instance.new("Frame")
	swatch.LayoutOrder = 1
	swatch.Size = UDim2.fromOffset(14, 14)
	swatch.BackgroundColor3 = Territories.ColorOf(player)
	swatch.BorderSizePixel = 0
	swatch.Parent = row
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = swatch

	local name = text(row, 2, 14, player == Players.LocalPlayer)
	name.Text = player.DisplayName
	local stats = text(row, 3, 13, false)
	stats.TextColor3 = Color3.fromRGB(200, 200, 205)
	stats.Text = `{held} territories · {armies} armies`
end

function TerritoryHud.start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "TerritoryHud"
	gui.ResetOnSpawn = false

	local playersPanel = panel("Players", gui)
	playersPanel.Position = UDim2.fromOffset(8, 48)

	local detail = panel("Selected", gui)
	detail.AnchorPoint = Vector2.new(0.5, 1)
	detail.Position = UDim2.new(0.5, 0, 1, -12)
	detail.Visible = false
	local title = text(detail, 1, 18, true)
	local continentLine = text(detail, 2, 14, false)
	local ownerLine = text(detail, 3, 14, false)
	local troopsLine = text(detail, 4, 14, false)
	local neighborsLine = text(detail, 5, 13, false)
	neighborsLine.TextColor3 = Color3.fromRGB(200, 200, 205)

	local function refreshPlayers()
		for _, child in playersPanel:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local heading = text(playersPanel, 0, 14, true)
		heading.Text = `Players ({#Players:GetPlayers()}/{#GameConfig.Seats})`

		local held: { [number]: number } = {}
		local armies: { [number]: number } = {}
		for _, id in Territories.Ids() do
			local owner = Territories.OwnerId(id)
			held[owner] = (held[owner] or 0) + 1
			armies[owner] = (armies[owner] or 0) + Territories.Troops(id)
		end
		for _, player in Players:GetPlayers() do
			local seat = player:GetAttribute("Seat")
			if typeof(seat) == "number" then
				playerRow(playersPanel, seat, player, held[player.UserId] or 0, armies[player.UserId] or 0)
			end
		end
	end

	local function refreshDetail()
		local id = TerritorySelection.Get()
		local territory = if id then Territories.Get(id) else nil
		detail.Visible = territory ~= nil
		if not id or not territory then
			return
		end
		title.Text = `{territory.id} · {territory.name}`
		local continent = if territory.continent then Territories.GetContinent(territory.continent) else nil
		continentLine.Text = if continent then `Continent: {continent.name} (+{continent.bonus})` else "Continent: none"
		local owner = Territories.Owner(id)
		ownerLine.Text = `Owner: {if owner then owner.DisplayName else "Neutral"}`
		ownerLine.TextColor3 = Territories.ColorOf(owner):Lerp(Color3.new(1, 1, 1), 0.35)
		troopsLine.Text = `Armies: {Territories.Troops(id)}`
		neighborsLine.Text = `Borders {#territory.neighbors} territories`
	end

	-- Many attributes change at once when the board is dealt; redraw once.
	local queued = false
	local function refresh()
		if queued then
			return
		end
		queued = true
		task.defer(function()
			queued = false
			refreshPlayers()
			refreshDetail()
		end)
	end

	Territories.State().AttributeChanged:Connect(refresh)
	TerritorySelection.Changed:Connect(refresh)
	local function watchPlayer(player: Player)
		player:GetAttributeChangedSignal("Seat"):Connect(refresh)
		refresh()
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(refresh)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

return TerritoryHud
