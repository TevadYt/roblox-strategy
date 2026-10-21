--!strict
-- Runs matches. Waits until enough players are seated, deals the board
-- through TerritoryService, then plays the turn and combat rules (Rules/Match)
-- on it until one player is left, and starts over.
--
-- Clients see the match through Shared.MatchState and ask for moves with the
-- MatchRequest remote. Every request is checked by the rules on the server;
-- a refused one is answered with a "Rejected" MatchEvent to that player only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MapData = require(ReplicatedStorage.Shared.MapData) :: any
local MatchState = require(ReplicatedStorage.Shared.MatchState)
local Board = require(script.Parent.Parent.Rules.Board)
local Match = require(script.Parent.Parent.Rules.Match)
local PlayerService = require(script.Parent.PlayerService) :: any
local TerritoryService = require(script.Parent.TerritoryService) :: any

local config = GameConfig.Match

local MatchService = {}

local board = Board.fromMapData(MapData)
local rng = Random.new()
local state: Folder
local eventRemote: RemoteEvent
local current: Match.Match? = nil
local playersById: { [number]: Player } = {}
local lastRequest: { [Player]: number } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function random(min: number, max: number): number
	return rng:NextInteger(min, max)
end

-- The rules see owners as UserIds and 0 for neutral; TerritoryService keeps
-- Player instances. A UserId whose player has left maps to neutral.
local store: Match.Store = {
	getOwner = function(id: number): number
		local owner = TerritoryService:GetOwner(id)
		return if owner then owner.UserId else Match.Neutral
	end,
	setOwner = function(id: number, userId: number)
		TerritoryService:SetOwner(id, playersById[userId])
	end,
	getArmies = function(id: number): number
		return TerritoryService:GetTroops(id)
	end,
	setArmies = function(id: number, armies: number)
		TerritoryService:SetTroops(id, armies)
	end,
}

local function setLobby(phase: string, endsAt: number)
	state:SetAttribute("Phase", phase)
	state:SetAttribute("PhaseEndsAt", endsAt)
	state:SetAttribute("CurrentPlayer", 0)
	state:SetAttribute("Reinforcements", 0)
end

-- Mirrors the match to the state folder and broadcasts what happened.
local function flush()
	local match = current
	if not match then
		return
	end
	for _, event in match:TakeEvents() do
		if event.kind == "Eliminated" then
			local player = playersById[event.player]
			if player then
				player:SetAttribute("Eliminated", true)
			end
		end
		eventRemote:FireAllClients(event.kind, event)
	end

	local occupation = match.occupation
	state:SetAttribute("Phase", match.phase)
	state:SetAttribute("CurrentPlayer", match:CurrentPlayer() or 0)
	state:SetAttribute("Turn", match.turn)
	state:SetAttribute("PhaseEndsAt", match.endsAt)
	state:SetAttribute("Reinforcements", match.reinforcements)
	state:SetAttribute("OccupyFrom", if occupation then occupation.from else 0)
	state:SetAttribute("OccupyTo", if occupation then occupation.to else 0)
	state:SetAttribute("OccupyMax", if occupation then occupation.max else 0)
	state:SetAttribute("Winner", match.winner or 0)
end

local function handle(match: Match.Match, userId: number, action: string, a: any, b: any, c: any): (boolean, string?)
	if action == "Place" then
		return match:Place(userId, a, b)
	elseif action == "Attack" then
		return match:Attack(userId, a, b, c)
	elseif action == "Occupy" then
		return match:Occupy(userId, a)
	elseif action == "EndAttack" then
		return match:EndAttack(userId)
	elseif action == "Fortify" then
		return match:Fortify(userId, a, b, c)
	elseif action == "EndTurn" then
		return match:EndTurn(userId)
	end
	return false, "UnknownAction"
end

local function onRequest(player: Player, action: any, a: any, b: any, c: any)
	if type(action) ~= "string" or not MatchState.Actions[action] then
		return
	end
	local clock = os.clock()
	if clock - (lastRequest[player] or 0) < config.RequestCooldown then
		eventRemote:FireClient(player, "Rejected", { action = action, reason = "TooFast" })
		return
	end
	lastRequest[player] = clock

	local match = current
	if not match then
		eventRemote:FireClient(player, "Rejected", { action = action, reason = "NoMatch" })
		return
	end
	local ok, reason = handle(match, player.UserId, action, a, b, c)
	if not ok then
		eventRemote:FireClient(player, "Rejected", { action = action, reason = reason })
	end
	flush()
end

-- Seated players once at least MinPlayers have been seated for a full
-- countdown.
local function waitForPlayers(): { Player }
	while true do
		local seated = PlayerService:GetSeatedPlayers()
		if #seated < config.MinPlayers then
			setLobby("Waiting", 0)
			task.wait(1)
		else
			local endsAt = now() + config.StartCountdown
			setLobby("Starting", endsAt)
			while now() < endsAt and #PlayerService:GetSeatedPlayers() >= config.MinPlayers do
				task.wait(0.5)
			end
			seated = PlayerService:GetSeatedPlayers()
			if #seated >= config.MinPlayers then
				return seated
			end
		end
	end
end

local function playMatch(players: { Player })
	table.clear(playersById)
	local ids = {}
	for _, player in players do
		playersById[player.UserId] = player
		player:SetAttribute("Eliminated", false)
		table.insert(ids, player.UserId)
	end

	TerritoryService:Deal(players)
	local match = Match.new(board, store, ids, config, random, now)
	current = match
	flush()

	while match.phase ~= "Over" do
		task.wait(0.25)
		match:Tick()
		flush()
	end
	task.wait(config.PostGameDelay)
	current = nil
end

function MatchService:Init()
	state = MatchState.Folder()
	eventRemote = MatchState.Event()
	setLobby("Waiting", 0)
end

function MatchService:Start()
	MatchState.Request().OnServerEvent:Connect(onRequest)
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
		local match = current
		if match and playersById[player.UserId] == player then
			match:RemovePlayer(player.UserId)
			flush()
			playersById[player.UserId] = nil
		end
	end)

	while true do
		playMatch(waitForPlayers())
	end
end

return MatchService
