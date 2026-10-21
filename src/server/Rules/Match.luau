--!strict
-- The turn and combat rules of one match, with no Roblox dependencies so they
-- can be tested outside Studio. Players are numbers (UserIds); territory
-- ownership and troop counts are read and written through a Store, so the
-- game can keep them wherever it replicates them. Owner 0 means neutral.
--
-- A turn is Reinforce -> Attack (-> Occupy after each conquest) -> Fortify.
-- Every action returns (true) or (false, reason). What happened is queued as
-- events; the caller drains them with TakeEvents and broadcasts them.

local Board = require(script.Parent.Board)
local Dice = require(script.Parent.Dice)

type Board = Board.Board
type Random = Dice.Random

export type Phase = "Reinforce" | "Attack" | "Occupy" | "Fortify" | "Over"

export type Rules = {
	MinReinforcements: number,
	TerritoriesPerReinforcement: number,
	MaxAttackDice: number,
	MaxDefendDice: number,
	-- true: fortify between any two of your territories joined by your own
	-- territories. false: only between neighbors.
	FortifyAlongPath: boolean,
	PhaseTimeouts: { [string]: number },
}

export type Store = {
	getOwner: (id: number) -> number,
	setOwner: (id: number, owner: number) -> (),
	getArmies: (id: number) -> number,
	setArmies: (id: number, armies: number) -> (),
}

export type Event = { kind: string, [string]: any }

type Occupation = { from: number, to: number, max: number }

type MatchData = {
	board: Board,
	store: Store,
	rules: Rules,
	random: Random,
	clock: () -> number,
	order: { number },
	active: { [number]: boolean },
	current: number,
	turn: number,
	phase: Phase,
	endsAt: number,
	attackEndsAt: number,
	reinforcements: number,
	occupation: Occupation?,
	winner: number?,
	events: { Event },
}

local NEUTRAL = 0

local Match = {}
Match.__index = Match
Match.Neutral = NEUTRAL

export type Match = typeof(setmetatable({} :: MatchData, Match))

local function isCount(value: any): boolean
	return type(value) == "number" and value >= 1 and value == math.floor(value) and value < math.huge
end

local function shuffle<T>(list: { T }, random: Random)
	for i = #list, 2, -1 do
		local j = random(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

-- Deals every territory round-robin in random order with 1 army each, then
-- spreads the rest of `startingArmies` per player over their own territories.
-- The game normally lets TerritoryService deal; this is for tests and tools.
function Match.deal(board: Board, store: Store, players: { number }, startingArmies: number, random: Random)
	local ids = table.clone(board.ids)
	shuffle(ids, random)
	local owned: { [number]: { number } } = {}
	for _, player in players do
		owned[player] = {}
	end
	for index, id in ids do
		local player = players[(index - 1) % #players + 1]
		store.setOwner(id, player)
		store.setArmies(id, 1)
		table.insert(owned[player], id)
	end
	for _, player in players do
		local mine = owned[player]
		for _ = 1, startingArmies - #mine do
			local id = mine[random(1, #mine)]
			store.setArmies(id, store.getArmies(id) + 1)
		end
	end
end

-- Starts a match on an already dealt board. Turn order is shuffled. Players
-- who own nothing are out from the start.
function Match.new(
	board: Board,
	store: Store,
	players: { number },
	rules: Rules,
	random: Random,
	clock: () -> number
): Match
	local self = setmetatable(
		{
			board = board,
			store = store,
			rules = rules,
			random = random,
			clock = clock,
			order = table.clone(players),
			active = {},
			current = 0,
			turn = 0,
			phase = "Reinforce" :: Phase,
			endsAt = 0,
			attackEndsAt = 0,
			reinforcements = 0,
			occupation = nil,
			winner = nil,
			events = {},
		} :: MatchData,
		Match
	)

	shuffle(self.order, random)
	for _, player in self.order do
		self.active[player] = #self:TerritoriesOf(player) > 0
	end
	if not self:_checkGameOver() then
		self:_startTurn(self:_nextActiveIndex(0))
	end
	return self
end

-- Reading state ---------------------------------------------------------------

function Match.CurrentPlayer(self: Match): number?
	if self.phase == "Over" then
		return nil
	end
	return self.order[self.current]
end

function Match.IsActive(self: Match, player: number): boolean
	return self.active[player] == true
end

function Match.TerritoriesOf(self: Match, player: number): { number }
	local result = {}
	for _, id in self.board.ids do
		if self.store.getOwner(id) == player then
			table.insert(result, id)
		end
	end
	return result
end

function Match.ReinforcementsFor(self: Match, player: number): number
	local count = #self:TerritoriesOf(player)
	local total = math.max(self.rules.MinReinforcements, count // self.rules.TerritoriesPerReinforcement)
	for _, continent in self.board.continents do
		local ownsAll = true
		for _, id in continent.territories do
			if self.store.getOwner(id) ~= player then
				ownsAll = false
				break
			end
		end
		if ownsAll then
			total += continent.bonus
		end
	end
	return total
end

function Match.TakeEvents(self: Match): { Event }
	local events = self.events
	self.events = {}
	return events
end

-- Internal --------------------------------------------------------------------

function Match._emit(self: Match, event: Event)
	table.insert(self.events, event)
end

function Match._setPhase(self: Match, phase: Phase, endsAt: number?)
	self.phase = phase
	self.endsAt = endsAt or (self.clock() + (self.rules.PhaseTimeouts[phase] or 0))
	self:_emit({ kind = "PhaseChanged", phase = phase, player = self:CurrentPlayer(), endsAt = self.endsAt })
end

function Match._nextActiveIndex(self: Match, from: number): number
	for step = 1, #self.order do
		local index = (from + step - 1) % #self.order + 1
		if self.active[self.order[index]] then
			return index
		end
	end
	return 0
end

function Match._startTurn(self: Match, index: number)
	local player = self.order[index]
	self.current = index
	self.turn += 1
	self.occupation = nil
	self.reinforcements = self:ReinforcementsFor(player)
	self:_emit({ kind = "TurnStarted", player = player, turn = self.turn, reinforcements = self.reinforcements })
	self:_setPhase("Reinforce")
end

function Match._advanceTurn(self: Match)
	if self:_checkGameOver() then
		return
	end
	self:_startTurn(self:_nextActiveIndex(self.current))
end

function Match._checkGameOver(self: Match): boolean
	if self.phase == "Over" then
		return true
	end
	local remaining = {}
	for _, player in self.order do
		if self.active[player] then
			table.insert(remaining, player)
		end
	end
	if #remaining > 1 then
		return false
	end
	self.winner = remaining[1]
	self.occupation = nil
	self:_setPhase("Over", 0)
	self:_emit({ kind = "GameOver", winner = self.winner })
	return true
end

function Match._eliminate(self: Match, player: number, by: number?)
	if not self.active[player] then
		return
	end
	self.active[player] = false
	self:_emit({ kind = "Eliminated", player = player, by = by })
end

function Match._check(self: Match, player: number, phase: Phase): (boolean, string?)
	if self.phase == "Over" then
		return false, "GameOver"
	end
	if self:CurrentPlayer() ~= player then
		return false, "NotYourTurn"
	end
	if self.phase ~= phase then
		return false, "WrongPhase"
	end
	return true
end

function Match._placeRandomly(self: Match, player: number, count: number)
	local mine = self:TerritoriesOf(player)
	if #mine == 0 then
		return
	end
	local placed: { [number]: number } = {}
	for _ = 1, count do
		local id = mine[self.random(1, #mine)]
		placed[id] = (placed[id] or 0) + 1
	end
	for id, amount in placed do
		self.store.setArmies(id, self.store.getArmies(id) + amount)
		self:_emit({ kind = "Placed", player = player, territory = id, count = amount })
	end
end

-- Whether `to` can be reached from `from` through territories `player` owns.
function Match._connected(self: Match, player: number, from: number, to: number): boolean
	local seen = { [from] = true }
	local queue = { from }
	local head = 1
	while head <= #queue do
		local id = queue[head]
		head += 1
		for other in self.board.neighbors[id] do
			if not seen[other] and self.store.getOwner(other) == player then
				if other == to then
					return true
				end
				seen[other] = true
				table.insert(queue, other)
			end
		end
	end
	return false
end

-- Actions ---------------------------------------------------------------------

function Match.Place(self: Match, player: number, territory: any, count: any): (boolean, string?)
	local ok, reason = self:_check(player, "Reinforce")
	if not ok then
		return false, reason
	end
	if not Board.has(self.board, territory) or self.store.getOwner(territory) ~= player then
		return false, "NotYourTerritory"
	end
	if not isCount(count) or count > self.reinforcements then
		return false, "BadCount"
	end

	self.store.setArmies(territory, self.store.getArmies(territory) + count)
	self.reinforcements -= count
	self:_emit({ kind = "Placed", player = player, territory = territory, count = count })
	if self.reinforcements == 0 then
		self:_setPhase("Attack")
	end
	return true
end

function Match.Attack(self: Match, player: number, from: any, to: any, dice: any): (boolean, string?)
	local ok, reason = self:_check(player, "Attack")
	if not ok then
		return false, reason
	end
	if not Board.has(self.board, from) or self.store.getOwner(from) ~= player then
		return false, "NotYourTerritory"
	end
	if not Board.has(self.board, to) or not Board.areNeighbors(self.board, from, to) then
		return false, "NotNeighbor"
	end
	local defender = self.store.getOwner(to)
	if defender == player then
		return false, "OwnTerritory"
	end
	local attackers = self.store.getArmies(from)
	if attackers < 2 then
		return false, "NotEnoughArmies"
	end
	if not isCount(dice) or dice > math.min(self.rules.MaxAttackDice, attackers - 1) then
		return false, "BadDice"
	end

	local defenders = self.store.getArmies(to)
	local result = Dice.battle(self.random, dice, math.min(self.rules.MaxDefendDice, defenders))
	attackers -= result.attackerLosses
	defenders -= result.defenderLosses
	local conquered = defenders <= 0

	self.store.setArmies(from, attackers)
	self:_emit({
		kind = "Battle",
		attacker = player,
		defender = defender,
		from = from,
		to = to,
		attackRolls = result.attackRolls,
		defendRolls = result.defendRolls,
		attackerLosses = result.attackerLosses,
		defenderLosses = result.defenderLosses,
		conquered = conquered,
	})

	if not conquered then
		self.store.setArmies(to, defenders)
		return true
	end

	-- A conquering roll never costs the attacker armies, so `attackers - 1`
	-- is at least `dice`. The dice that won move in at once so the territory
	-- is never empty; Occupy may move more.
	self.store.setOwner(to, player)
	self.store.setArmies(to, dice)
	self.store.setArmies(from, attackers - dice)
	self:_emit({ kind = "Conquered", player = player, from = from, to = to, previousOwner = defender, moved = dice })

	if defender ~= NEUTRAL and #self:TerritoriesOf(defender) == 0 then
		self:_eliminate(defender, player)
		if self:_checkGameOver() then
			return true
		end
	end

	local extra = attackers - dice - 1
	if extra > 0 then
		self.occupation = { from = from, to = to, max = extra }
		self.attackEndsAt = self.endsAt
		self:_setPhase("Occupy")
	end
	return true
end

-- After a conquest, moves 0..max more armies into the conquered territory.
function Match.Occupy(self: Match, player: number, count: any): (boolean, string?)
	local ok, reason = self:_check(player, "Occupy")
	if not ok then
		return false, reason
	end
	local occupation = self.occupation :: Occupation
	if type(count) ~= "number" or count ~= math.floor(count) or count < 0 or count > occupation.max then
		return false, "BadCount"
	end
	self:_finishOccupy(count)
	return true
end

function Match._finishOccupy(self: Match, count: number)
	local occupation = self.occupation :: Occupation
	self.occupation = nil
	if count > 0 then
		self.store.setArmies(occupation.from, self.store.getArmies(occupation.from) - count)
		self.store.setArmies(occupation.to, self.store.getArmies(occupation.to) + count)
		self:_emit({
			kind = "Moved",
			player = self.order[self.current],
			from = occupation.from,
			to = occupation.to,
			count = count,
		})
	end
	-- Back to attacking on the clock the attack phase already had.
	self:_setPhase("Attack", self.attackEndsAt)
end

function Match.EndAttack(self: Match, player: number): (boolean, string?)
	local ok, reason = self:_check(player, "Attack")
	if not ok then
		return false, reason
	end
	self:_setPhase("Fortify")
	return true
end

-- One move per turn between two of your territories, then the turn ends.
function Match.Fortify(self: Match, player: number, from: any, to: any, count: any): (boolean, string?)
	local ok, reason = self:_check(player, "Fortify")
	if not ok then
		return false, reason
	end
	if not Board.has(self.board, from) or self.store.getOwner(from) ~= player then
		return false, "NotYourTerritory"
	end
	if not Board.has(self.board, to) or self.store.getOwner(to) ~= player or from == to then
		return false, "NotYourTerritory"
	end
	local reachable = if self.rules.FortifyAlongPath
		then self:_connected(player, from, to)
		else Board.areNeighbors(self.board, from, to)
	if not reachable then
		return false, "NotConnected"
	end
	if not isCount(count) or count > self.store.getArmies(from) - 1 then
		return false, "BadCount"
	end

	self.store.setArmies(from, self.store.getArmies(from) - count)
	self.store.setArmies(to, self.store.getArmies(to) + count)
	self:_emit({ kind = "Moved", player = player, from = from, to = to, count = count })
	self:_advanceTurn()
	return true
end

-- Ends the turn from the attack or fortify phase.
function Match.EndTurn(self: Match, player: number): (boolean, string?)
	if self.phase == "Over" then
		return false, "GameOver"
	end
	if self:CurrentPlayer() ~= player then
		return false, "NotYourTurn"
	end
	if self.phase ~= "Attack" and self.phase ~= "Fortify" then
		return false, "WrongPhase"
	end
	self:_advanceTurn()
	return true
end

-- A player who leaves is out; their territories stay on the board as neutral
-- with their armies, so anyone can take them.
function Match.RemovePlayer(self: Match, player: number)
	if not self.active[player] or self.phase == "Over" then
		return
	end
	local wasCurrent = self:CurrentPlayer() == player
	for _, id in self:TerritoriesOf(player) do
		self.store.setOwner(id, NEUTRAL)
	end
	self:_eliminate(player, nil)
	if wasCurrent then
		self:_advanceTurn()
	else
		self:_checkGameOver()
	end
end

-- Call regularly. When the phase clock runs out the game acts for the player:
-- unplaced reinforcements go to random territories of theirs, a pending
-- occupation moves nothing extra, and attack or fortify ends the turn.
function Match.Tick(self: Match)
	if self.phase == "Over" or self.clock() < self.endsAt then
		return
	end
	local player = self.order[self.current]
	if self.phase == "Reinforce" then
		self:_placeRandomly(player, self.reinforcements)
		self.reinforcements = 0
		self:_setPhase("Attack")
	elseif self.phase == "Occupy" then
		self:_finishOccupy(0)
	else
		self:_advanceTurn()
	end
end

return Match
