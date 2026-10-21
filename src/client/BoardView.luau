--!strict
-- Shows the replicated territory state on the board: each territory's slab is
-- tinted toward its owner's seat color, a badge over its center shows the
-- army count, and the selected territory and its neighbours are outlined.
-- Display only; the server owns the state.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Territories = require(ReplicatedStorage.Shared.Territories)
local TerritorySelection = require(script.Parent.TerritorySelection)

-- Studs above a territory's surface. MapBuilder sets each territory's
-- surface height as the model's "Top" attribute; until the model arrives the
-- badge sits at the lowest likely height.
local BADGE_LIFT = 1

local BoardView = {}

-- Terrain color of every slab part, so tinting never compounds.
local baseColors: { [BasePart]: Color3 } = {}
local models: { [number]: Model } = {}
local badges: { [number]: TextLabel } = {}
local anchors: { [number]: BasePart } = {}
local selectedHighlight: Highlight? = nil
local neighborHighlights: { Highlight } = {}

local function tintFor(id: number, base: Color3): Color3
	local owner = Territories.Owner(id)
	if not owner then
		return base
	end
	return base:Lerp(Territories.ColorOf(owner), GameConfig.Territories.OwnerTint)
end

local function paintPart(id: number, part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	local base = baseColors[part]
	if not base then
		base = part.Color
		baseColors[part] = base
	end
	part.Color = tintFor(id, base)
end

local function paint(id: number)
	local model = models[id]
	local slab = model and model:FindFirstChild("Slab")
	if slab then
		for _, part in slab:GetChildren() do
			paintPart(id, part)
		end
	end

	local badge = badges[id]
	if badge then
		badge.Text = tostring(Territories.Troops(id))
		badge.BackgroundColor3 = Territories.ColorOf(Territories.Owner(id))
	end
end

local function track(model: Instance)
	local id = model:GetAttribute("Id")
	if not model:IsA("Model") or typeof(id) ~= "number" then
		return
	end
	models[id] = model
	local top = model:GetAttribute("Top")
	local anchor = anchors[id]
	if anchor and typeof(top) == "number" then
		anchor.Position = Territories.WorldCenter(id, top + BADGE_LIFT)
	end
	local function watchSlab(slab: Instance)
		-- Parts can arrive later with streaming; paint them as they do.
		slab.ChildAdded:Connect(function(part)
			paintPart(id, part)
		end)
		paint(id)
	end
	local slab = model:FindFirstChild("Slab")
	if slab then
		watchSlab(slab)
	else
		model.ChildAdded:Connect(function(child)
			if child.Name == "Slab" then
				watchSlab(child)
			end
		end)
	end
end

local function makeBadge(id: number, folder: Folder, gui: ScreenGui)
	-- A local, invisible anchor, so the badge doesn't depend on the board's
	-- parts being streamed in.
	local anchor = Instance.new("Part")
	anchor.Name = `Anchor_{id}`
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = Territories.WorldCenter(id, BADGE_LIFT)
	anchors[id] = anchor
	anchor.Parent = folder

	local billboard = Instance.new("BillboardGui")
	billboard.Name = `Troops_{id}`
	billboard.Adornee = anchor
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(34, 24)
	-- Sit just above the board's own id/name label.
	billboard.SizeOffset = Vector2.new(0, 1.5)
	-- The 2D strategic camera sits far above the board.
	billboard.MaxDistance = math.huge
	billboard.Parent = gui

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.BorderSizePixel = 0
	label.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = label

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Color3.fromRGB(20, 20, 24)
	stroke.Thickness = 1.5
	stroke.Parent = label

	badges[id] = label
end

local function makeHighlight(color: Color3, fillTransparency: number): Highlight
	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = fillTransparency
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Parent = workspace
	return highlight
end

local function showSelection(id: number?)
	if selectedHighlight then
		selectedHighlight.Adornee = if id then models[id] else nil
		selectedHighlight.Enabled = id ~= nil and models[id] ~= nil
	end

	local territory = if id then Territories.Get(id) else nil
	local neighbors = if territory then territory.neighbors else {}
	for index, highlight in neighborHighlights do
		local model = models[neighbors[index]]
		highlight.Adornee = model
		highlight.Enabled = model ~= nil
	end
end

function BoardView.start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "TroopBadges"
	gui.ResetOnSpawn = false
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local anchorFolder = Instance.new("Folder")
	anchorFolder.Name = "TroopBadgeAnchors"
	anchorFolder.Parent = workspace

	for _, id in Territories.Ids() do
		makeBadge(id, anchorFolder, gui)
	end

	-- Highlights are capped per client, so keep a fixed pool: one for the
	-- selection and one per neighbour of the most connected territory.
	local most = 0
	for _, id in Territories.Ids() do
		local territory = Territories.Get(id)
		most = math.max(most, if territory then #territory.neighbors else 0)
	end
	for i = 1, most do
		neighborHighlights[i] = makeHighlight(Color3.fromRGB(255, 230, 120), 1)
	end
	selectedHighlight = makeHighlight(Color3.new(1, 1, 1), 0.75)

	local state = Territories.State()
	for _, id in Territories.Ids() do
		local function refresh()
			paint(id)
		end
		state:GetAttributeChangedSignal(Territories.OwnerAttribute(id)):Connect(refresh)
		state:GetAttributeChangedSignal(Territories.TroopsAttribute(id)):Connect(refresh)
		paint(id)
	end

	-- Owner colors come from the owner's Seat attribute, which may arrive
	-- after the territory state does.
	local function watchPlayer(player: Player)
		player:GetAttributeChangedSignal("Seat"):Connect(function()
			for _, id in Territories.Ids() do
				if Territories.OwnerId(id) == player.UserId then
					paint(id)
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	TerritorySelection.Changed:Connect(showSelection)

	task.spawn(function()
		local map = workspace:WaitForChild("Map")
		local board = map:WaitForChild("Territories")
		board.ChildAdded:Connect(function(model)
			track(model)
			showSelection(TerritorySelection.Get())
		end)
		for _, model in board:GetChildren() do
			track(model)
		end
		showSelection(TerritorySelection.Get())
	end)
end

return BoardView
