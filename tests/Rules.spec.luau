--!strict
-- Tests for the turn and combat rules. Run with `lune run tests/run`.

local Rules = script.Parent.Parent.src.server.Rules
local Board = require(Rules.Board)
local Dice = require(Rules.Dice)
local Match = require(Rules.Match)

-- 1 - 2 - 3 - 4 - 5 - 6 in a line; continent 1 is {1, 2}, continent 2 the rest.
local LINE = Board.fromMapData({
	territories = {
		{ id = 1, neighbors = { 2 }, continent = 1 },
		{ id = 2, neighbors = { 1, 3 }, continent = 1 },
		{ id = 3, neighbors = { 2, 4 }, continent = 2 },
		{ id = 4, neighbors = { 3, 5 }, continent = 2 },
		{ id = 5, neighbors = { 4, 6 }, continent = 2 },
		{ id = 6, neighbors = { 5 }, continent = 2 },
	},
	continents = {
		{ id = 1, territories = { 1, 2 }, bonus = 2 },
		{ id = 2, territories = { 3, 4, 5, 6 }, bonus = 5 },
	},
})

local RULES = {
	MinReinforcements = 3,
	TerritoriesPerReinforcement = 3,
	MaxAttackDice = 3,
	MaxDefendDice = 2,
	FortifyAlongPath = true,
	PhaseTimeouts = { Reinforce = 45, Attack = 90, Occupy = 15, Fortify = 30 },
}

local function makeStore(owners: { number }, armies: { number })
	local owner, count = table.clone(owners), table.clone(armies)
	return {
		getOwner = function(id: number)
			return owner[id] or 0
		end,
		setOwner = function(id: number, player: number)
			owner[id] = player
		end,
		getArmies = function(id: number)
			return count[id] or 0
		end,
		setArmies = function(id: number, value: number)
			assert(value >= 0, `armies of {id} went negative`)
			count[id] = value
		end,
	}
end

-- Returns the queued values in order, then each range's minimum.
local function scripted(values: { number })
	local index = 0
	return function(min: number, max: number): number
		index += 1
		local value = values[index] or min
		assert(value >= min and value <= max, `scripted roll {value} outside {min}..{max}`)
		return value
	end
end

local function fakeClock()
	local now = 0
	return function()
		return now
	end, function(seconds: number)
		now += seconds
	end
end

-- Two players, 10 then 20 (a scripted 2 keeps the shuffled order).
local function twoPlayers(owners: { number }, armies: { number }, rolls: { number }?)
	local store = makeStore(owners, armies)
	local clock, advance = fakeClock()
	local queue = { 2 }
	for _, roll in rolls or {} do
		table.insert(queue, roll)
	end
	local match = Match.new(LINE, store, { 10, 20 }, RULES, scripted(queue), clock)
	return match, store, advance
end

local function kinds(events: { { kind: string } }): string
	local list = {}
	for _, event in events do
		table.insert(list, event.kind)
	end
	return table.concat(list, ",")
end

test("dice: ties go to the defender", function()
	local attackerLosses, defenderLosses = Dice.compare({ 6, 3, 1 }, { 5, 3 })
	eq(attackerLosses, 1, "attacker losses")
	eq(defenderLosses, 1, "defender losses")
end)

test("dice: only as many pairs as the smaller side", function()
	local attackerLosses, defenderLosses = Dice.compare({ 2 }, { 6, 6 })
	eq(attackerLosses, 1, "attacker losses")
	eq(defenderLosses, 0, "defender losses")
end)

test("board: borders are symmetric", function()
	local board = Board.fromMapData({
		territories = {
			{ id = 1, neighbors = { 2 }, continent = 1 },
			{ id = 2, neighbors = {}, continent = 1 },
		},
		continents = { { id = 1, territories = { 1, 2 }, bonus = 1 } },
	})
	eq(Board.areNeighbors(board, 2, 1), true, "2 borders 1")
	eq(Board.has(board, 3), false, "unknown id")
	eq(Board.has(board, "1"), false, "string id")
end)

test("deal: every territory owned, armies match the starting count", function()
	local store = makeStore({}, {})
	local seed = 7
	local function lcg(min: number, max: number): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return min + seed % (max - min + 1)
	end
	Match.deal(LINE, store, { 10, 20, 30 }, 5, lcg)
	local totals = {}
	for id = 1, 6 do
		local owner = store.getOwner(id)
		assert(owner ~= 0, `territory {id} unowned`)
		totals[owner] = (totals[owner] or 0) + store.getArmies(id)
	end
	eq(totals[10], 5, "player 10 armies")
	eq(totals[20], 5, "player 20 armies")
	eq(totals[30], 5, "player 30 armies")
end)

test("reinforcements: minimum, territory count and continent bonus", function()
	local match = twoPlayers({ 10, 10, 10, 20, 20, 20 }, { 1, 1, 1, 1, 1, 1 })
	eq(match:ReinforcementsFor(10), 3 + 2, "10 holds continent 1")
	eq(match:ReinforcementsFor(20), 3, "20 holds nothing whole")
	local big = twoPlayers({ 10, 10, 10, 10, 10, 20 }, { 1, 1, 1, 1, 1, 1 })
	eq(big:ReinforcementsFor(10), 3 + 2, "5 territories still gives the minimum")
end)

test("a full turn: reinforce, attack, conquer, occupy, fortify", function()
	-- Rolls after the shuffle: attack 6,5,4 vs defend 1.
	local match, store = twoPlayers({ 10, 10, 10, 20, 20, 20 }, { 3, 1, 1, 1, 2, 1 }, { 6, 5, 4, 1 })
	eq(match:CurrentPlayer(), 10, "first player")
	eq(match.phase, "Reinforce", "phase")
	eq(match.reinforcements, 5, "reinforcements")

	eq(select(2, match:Place(20, 4, 1)), "NotYourTurn")
	eq(select(2, match:Place(10, 4, 1)), "NotYourTerritory")
	eq(select(2, match:Place(10, 3, 6)), "BadCount")
	eq(select(2, match:Place(10, 3, 1.5)), "BadCount")
	eq(select(2, match:Place(10, 3, "5")), "BadCount")
	eq(select(2, match:Place(10, 3, 0 / 0)), "BadCount")
	eq(select(2, match:Attack(10, 3, 4, 1)), "WrongPhase")
	assert(match:Place(10, 3, 2))
	assert(match:Place(10, 3, 3))
	eq(match.phase, "Attack", "all placed moves to attack")
	eq(store.getArmies(3), 6, "armies on 3")

	match:TakeEvents()
	eq(select(2, match:Attack(10, 3, 5, 1)), "NotNeighbor")
	eq(select(2, match:Attack(10, 3, 2, 1)), "OwnTerritory")
	eq(select(2, match:Attack(10, 2, 3, 1)), "OwnTerritory")
	eq(select(2, match:Attack(10, 3, 4, 4)), "BadDice")
	assert(match:Attack(10, 3, 4, 3))
	eq(kinds(match:TakeEvents()), "Battle,Conquered,PhaseChanged", "events")
	eq(store.getOwner(4), 10, "4 conquered")
	eq(store.getArmies(4), 3, "dice moved in")
	eq(store.getArmies(3), 3, "left behind")
	eq(match.phase, "Occupy", "may move more")

	eq(select(2, match:Attack(10, 4, 5, 1)), "WrongPhase")
	eq(select(2, match:Occupy(10, 3)), "BadCount")
	assert(match:Occupy(10, 2))
	eq(store.getArmies(3), 1, "3 after occupy")
	eq(store.getArmies(4), 5, "4 after occupy")
	eq(match.phase, "Attack", "back to attack")

	assert(match:EndAttack(10))
	eq(select(2, match:Fortify(10, 2, 4, 1)), "BadCount")
	eq(select(2, match:Fortify(10, 1, 5, 1)), "NotYourTerritory")
	assert(match:Fortify(10, 1, 4, 2))
	eq(store.getArmies(1), 1, "1 after fortify")
	eq(store.getArmies(4), 7, "4 after fortify")

	eq(match:CurrentPlayer(), 20, "turn passed")
	eq(match.phase, "Reinforce", "next player reinforces")
	eq(match.reinforcements, 3, "20 reinforcements")
end)

test("attack: a failed attack keeps ownership and needs 2 armies", function()
	-- Attack 3 vs defend 3: tie goes to the defender.
	local match, store = twoPlayers({ 10, 10, 10, 20, 20, 20 }, { 1, 1, 2, 1, 1, 1 }, { 3, 3 })
	assert(match:Place(10, 1, 5))
	eq(select(2, match:Attack(10, 2, 3, 1)), "OwnTerritory")
	assert(match:Attack(10, 3, 4, 1))
	eq(store.getOwner(4), 20, "still defender's")
	eq(store.getArmies(3), 1, "attacker lost one")
	eq(select(2, match:Attack(10, 3, 4, 1)), "NotEnoughArmies")
end)

test("fortify: must be connected through your own territories", function()
	local match = twoPlayers({ 10, 10, 20, 10, 20, 20 }, { 3, 1, 1, 1, 1, 1 })
	assert(match:Place(10, 1, 5))
	assert(match:EndAttack(10))
	eq(select(2, match:Fortify(10, 1, 4, 1)), "NotConnected")
	assert(match:Fortify(10, 1, 2, 1))
end)

test("conquering the last territory eliminates the defender and wins", function()
	local match, store = twoPlayers({ 10, 10, 10, 10, 10, 20 }, { 1, 1, 1, 1, 1, 1 }, { 6, 1 })
	assert(match:Place(10, 5, 5))
	match:TakeEvents()
	assert(match:Attack(10, 5, 6, 1))
	eq(kinds(match:TakeEvents()), "Battle,Conquered,Eliminated,PhaseChanged,GameOver", "events")
	eq(store.getOwner(6), 10, "6 conquered")
	eq(match.phase, "Over", "phase")
	eq(match.winner, 10, "winner")
	eq(match:CurrentPlayer(), nil, "nobody's turn")
	eq(select(2, match:EndTurn(10)), "GameOver")
end)

test("timeouts place reinforcements and end the turn", function()
	-- Random placement picks territory index 1 of {1, 2, 3} five times.
	local match, store, advance = twoPlayers({ 10, 10, 10, 20, 20, 20 }, { 1, 1, 1, 1, 1, 1 })
	match:Tick()
	eq(match.phase, "Reinforce", "nothing happens early")
	advance(45)
	match:Tick()
	eq(match.phase, "Attack", "reinforce timed out")
	eq(store.getArmies(1), 6, "placed for the player")
	advance(90)
	match:Tick()
	eq(match:CurrentPlayer(), 20, "attack timed out, turn passed")
end)

test("occupy timeout moves nothing extra and keeps the attack clock", function()
	local match, store, advance = twoPlayers({ 10, 10, 10, 20, 20, 20 }, { 1, 1, 1, 1, 1, 1 }, { 6, 1 })
	assert(match:Place(10, 3, 5))
	advance(80)
	assert(match:Attack(10, 3, 4, 1))
	eq(match.phase, "Occupy", "phase")
	advance(15)
	match:Tick()
	eq(match.phase, "Attack", "back to attack")
	eq(store.getArmies(4), 1, "only the die moved")
	eq(store.getArmies(3), 5, "rest stayed")
	match:Tick()
	eq(match:CurrentPlayer(), 20, "attack clock had already run out")
end)

test("a leaving player's land turns neutral and play moves on", function()
	local store = makeStore({ 10, 10, 20, 20, 30, 30 }, { 1, 1, 1, 1, 1, 1 })
	local clock = fakeClock()
	-- Shuffle of 3 rolls 3 then 2: order stays 10, 20, 30.
	local match = Match.new(LINE, store, { 10, 20, 30 }, RULES, scripted({ 3, 2 }), clock)
	eq(match:CurrentPlayer(), 10, "first")
	match:RemovePlayer(20)
	eq(store.getOwner(3), Match.Neutral, "3 neutral")
	eq(store.getArmies(3), 1, "armies stay")
	eq(match:CurrentPlayer(), 10, "still 10's turn")
	match:RemovePlayer(10)
	eq(match.phase, "Over", "one player left")
	eq(match.winner, 30, "last one wins")
end)

test("neutral territories can be attacked without eliminating anyone", function()
	local match, store = twoPlayers({ 10, 0, 20, 20, 20, 20 }, { 2, 1, 1, 1, 1, 1 }, { 6, 1 })
	assert(match:Place(10, 1, 3))
	match:TakeEvents()
	assert(match:Attack(10, 1, 2, 1))
	eq(store.getOwner(2), 10, "neutral taken")
	eq(match.phase, "Occupy", "can move more")
	assert(match:Occupy(10, 0))
	eq(match.phase, "Attack", "back")
end)

test("six bots play a whole match on the real map", function()
	local board = Board.fromMapData(require(script.Parent.Parent.src.shared.MapData) :: any)
	local seed = 12345
	local function lcg(min: number, max: number): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return min + (seed // 65536) % (max - min + 1)
	end
	local store = makeStore({}, {})
	local players = { 1, 2, 3, 4, 5, 6 }
	Match.deal(board, store, players, 20, lcg)
	local clock = fakeClock()
	local match = Match.new(board, store, players, RULES, lcg, clock)

	local function frontline(player: number): { number }
		local result = {}
		for _, id in match:TerritoriesOf(player) do
			for other in board.neighbors[id] do
				if store.getOwner(other) ~= player then
					table.insert(result, id)
					break
				end
			end
		end
		return result
	end

	local function checkBoard()
		for _, id in board.ids do
			assert(store.getArmies(id) >= 1, `territory {id} has {store.getArmies(id)} armies`)
		end
	end

	local actions = 0
	while match.phase ~= "Over" do
		actions += 1
		assert(actions < 20000, "match did not finish")
		local player = match:CurrentPlayer() :: number
		if match.phase == "Reinforce" then
			local front = frontline(player)
			assert(match:Place(player, front[lcg(1, #front)], match.reinforcements))
		elseif match.phase == "Occupy" then
			assert(match:Occupy(player, (match.occupation :: any).max))
		elseif match.phase == "Attack" then
			local best, target = nil, nil
			for _, id in frontline(player) do
				if not best or store.getArmies(id) > store.getArmies(best) then
					best = id
				end
			end
			if best and store.getArmies(best) >= 3 then
				for other in board.neighbors[best] do
					if store.getOwner(other) ~= player then
						target = other
						break
					end
				end
				assert(match:Attack(player, best, target, math.min(3, store.getArmies(best) - 1)))
			else
				assert(match:EndTurn(player))
			end
		else
			assert(match:EndTurn(player))
		end
		checkBoard()
	end

	local winner = match.winner :: number
	assert(winner, "no winner")
	for _, player in players do
		eq(match:IsActive(player), player == winner, `player {player} active`)
	end
	eq(#match:TerritoriesOf(winner), #board.ids, "winner holds the whole map")
end)
