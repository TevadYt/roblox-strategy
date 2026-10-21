--!strict
-- Turn bar and action buttons. Shows whose turn it is, the phase and its
-- clock, and lets the current player act on the board selection:
--   Reinforce: select your territory, place armies on it.
--   Attack:    select your territory, then an enemy neighbor, attack.
--   Occupy:    choose how many more armies follow the conquest.
--   Fortify:   select your territory, then another of yours, move armies.
-- Every button only sends a request; the server decides.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MatchState = require(ReplicatedStorage.Shared.MatchState)
local Territories = require(ReplicatedStorage.Shared.Territories)
local TerritorySelection = require(script.Parent.TerritorySelection)

local MatchHud = {}

local BACKGROUND = Color3.fromRGB(20, 20, 24)
local BUTTON = Color3.fromRGB(60, 64, 80)

local player = Players.LocalPlayer

local function label(parent: Instance, order: number, size: number): TextLabel
	local text = Instance.new("TextLabel")
	text.LayoutOrder = order
	text.AutomaticSize = Enum.AutomaticSize.XY
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextSize = size
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Parent = parent
	return text
end

local function nameOf(userId: number): string
	local other = Players:GetPlayerByUserId(userId)
	return if other then other.DisplayName else "Someone"
end

local function territoryName(id: number?): string
	local territory = if id then Territories.Get(id) else nil
	return if territory then `{territory.id} {territory.name}` else "-"
end

function MatchHud.start()
	local state = MatchState.Folder()
	local request = MatchState.Request()
	local events = MatchState.Event()

	local gui = Instance.new("ScreenGui")
	gui.Name = "MatchHud"
	gui.ResetOnSpawn = false

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.Position = UDim2.new(1, -8, 1, -8)
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.BackgroundColor3 = BACKGROUND
	frame.BackgroundTransparency = 0.25
	frame.Parent = gui

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
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	local status = label(frame, 1, 16)
	local hint = label(frame, 2, 13)
	local log = label(frame, 3, 13)
	log.TextColor3 = Color3.fromRGB(255, 220, 140)

	local row = Instance.new("Frame")
	row.LayoutOrder = 4
	row.AutomaticSize = Enum.AutomaticSize.XY
	row.BackgroundTransparency = 1
	row.Parent = frame
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.Padding = UDim.new(0, 6)
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = row

	-- The last own territory selected before the current selection: the
	-- "from" side of an attack or a fortify move.
	local source: number? = nil
	local previous: number? = TerritorySelection.Get()

	local function mine(id: number?): boolean
		return id ~= nil and Territories.OwnerId(id) == player.UserId
	end

	local function number(name: string): number
		local value = state:GetAttribute(name)
		return if type(value) == "number" then value else 0
	end

	local function phase(): string
		local value = state:GetAttribute("Phase")
		return if type(value) == "string" then value else "Waiting"
	end

	local function myTurn(): boolean
		return number("CurrentPlayer") == player.UserId
	end

	local function send(action: string, ...: any)
		request:FireServer(action, ...)
	end

	type ButtonSpec = { text: string, onClick: () -> () }

	local function buttons(): { ButtonSpec }
		if not myTurn() then
			return {}
		end
		local selected = TerritorySelection.Get()
		local current = phase()
		if current == "Reinforce" then
			local left = number("Reinforcements")
			return {
				{
					text = "Place 1",
					onClick = function()
						send("Place", selected, 1)
					end,
				},
				{
					text = `Place all ({left})`,
					onClick = function()
						send("Place", selected, left)
					end,
				},
			}
		elseif current == "Attack" then
			return {
				{
					text = "Attack",
					onClick = function()
						if source then
							local dice = math.min(GameConfig.Match.MaxAttackDice, Territories.Troops(source) - 1)
							send("Attack", source, selected, dice)
						end
					end,
				},
				{
					text = "Stop attacking",
					onClick = function()
						send("EndAttack")
					end,
				},
				{
					text = "End turn",
					onClick = function()
						send("EndTurn")
					end,
				},
			}
		elseif current == "Occupy" then
			local max = number("OccupyMax")
			return {
				{
					text = `Move {max} more`,
					onClick = function()
						send("Occupy", max)
					end,
				},
				{
					text = "Stay",
					onClick = function()
						send("Occupy", 0)
					end,
				},
			}
		elseif current == "Fortify" then
			return {
				{
					text = "Move all but 1",
					onClick = function()
						if source then
							send("Fortify", source, selected, Territories.Troops(source) - 1)
						end
					end,
				},
				{
					text = "End turn",
					onClick = function()
						send("EndTurn")
					end,
				},
			}
		end
		return {}
	end

	local function hintText(): string
		local current = phase()
		if current == "Waiting" then
			return `Waiting for {GameConfig.Match.MinPlayers} players`
		elseif current == "Over" then
			local winner = number("Winner")
			return if winner ~= 0 then `{nameOf(winner)} wins!` else "Match over"
		elseif not myTurn() then
			return ""
		end
		local selected = TerritorySelection.Get()
		if current == "Reinforce" then
			return `Select one of your territories. Selected: {territoryName(selected)}`
		elseif current == "Attack" then
			return `Select yours, then an enemy neighbor. {territoryName(source)} -> {territoryName(selected)}`
		elseif current == "Occupy" then
			return `Conquered {territoryName(number("OccupyTo"))}`
		elseif current == "Fortify" then
			return `Select yours, then another of yours. {territoryName(source)} -> {territoryName(selected)}`
		end
		return ""
	end

	local function rebuild()
		for _, child in row:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		for index, spec in buttons() do
			local button = Instance.new("TextButton")
			button.LayoutOrder = index
			button.AutomaticSize = Enum.AutomaticSize.X
			button.Size = UDim2.fromOffset(0, 28)
			button.BackgroundColor3 = BUTTON
			button.Font = Enum.Font.GothamBold
			button.TextSize = 14
			button.TextColor3 = Color3.new(1, 1, 1)
			button.Text = `  {spec.text}  `
			button.Activated:Connect(spec.onClick)
			button.Parent = row
			local round = Instance.new("UICorner")
			round.CornerRadius = UDim.new(0, 6)
			round.Parent = button
		end
		hint.Text = hintText()
	end

	local function refreshStatus()
		local current = phase()
		local endsAt = number("PhaseEndsAt")
		local left = math.max(0, math.ceil(endsAt - workspace:GetServerTimeNow()))
		local clock = if endsAt > 0 then ` · {left}s` else ""
		local turnOf = number("CurrentPlayer")
		if current == "Waiting" or current == "Starting" or current == "Over" then
			status.Text = `{current}{clock}`
		else
			local who = if turnOf == player.UserId then "Your turn" else `{nameOf(turnOf)}'s turn`
			local extra = if current == "Reinforce" then ` · {number("Reinforcements")} to place` else ""
			status.Text = `{who} · {current}{extra}{clock}`
		end
	end

	TerritorySelection.Changed:Connect(function(id: number?)
		if mine(previous) then
			source = previous
		end
		previous = id
		rebuild()
	end)
	state.AttributeChanged:Connect(function()
		refreshStatus()
		rebuild()
	end)

	events.OnClientEvent:Connect(function(kind: string, event: any)
		if kind == "Rejected" then
			log.Text = `Can't {event.action}: {event.reason}`
		elseif kind == "Battle" then
			local rolls = `{table.concat(event.attackRolls, " ")} vs {table.concat(event.defendRolls, " ")}`
			log.Text = `{territoryName(event.from)} attacks {territoryName(event.to)}: {rolls}`
				.. ` · attacker -{event.attackerLosses}, defender -{event.defenderLosses}`
		elseif kind == "Conquered" then
			log.Text = `{nameOf(event.player)} took {territoryName(event.to)}`
		elseif kind == "Eliminated" then
			log.Text = `{nameOf(event.player)} is out`
		elseif kind == "TurnStarted" then
			source = nil
		end
	end)

	RunService.Heartbeat:Connect(refreshStatus)
	refreshStatus()
	rebuild()
	gui.Parent = player:WaitForChild("PlayerGui")
end

return MatchHud
