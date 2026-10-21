--!strict
-- Read-only view of the board for both sides: static facts from MapData
-- (names, continents, neighbours) and the live ownership state the server
-- replicates on ReplicatedStorage.TerritoryState.
--
-- TerritoryState attributes, per territory id:
--   Owner_<id>  UserId of the owner, 0 when neutral
--   Troops_<id> armies on the territory
-- Only TerritoryService on the server writes them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(script.Parent.GameConfig)
local MapData = require(script.Parent.MapData) :: any

export type Territory = {
	id: number,
	name: string,
	continent: number?,
	neighbors: { number },
}

export type Continent = {
	id: number,
	name: string,
	bonus: number,
	territories: { number },
}

local STATE_NAME = "TerritoryState"

local Territories = {}

local byId: { [number]: Territory } = {}
local ids: { number } = {}
local neighborSets: { [number]: { [number]: boolean } } = {}
local continents: { [number]: Continent } = {}

for _, t in MapData.territories do
	local territory: Territory = {
		id = t.id,
		name = t.name,
		continent = t.continent,
		neighbors = t.neighbors,
	}
	byId[t.id] = territory
	table.insert(ids, t.id)
	local set = {}
	for _, n in t.neighbors do
		set[n] = true
	end
	neighborSets[t.id] = set
end
table.sort(ids)

for _, c in MapData.continents do
	continents[c.id] = {
		id = c.id,
		name = c.name,
		bonus = c.bonus,
		territories = c.territories,
	}
end

function Territories.Get(id: number): Territory?
	return byId[id]
end

-- Every territory id, ascending.
function Territories.Ids(): { number }
	return table.clone(ids)
end

function Territories.Count(): number
	return #ids
end

function Territories.AreNeighbors(a: number, b: number): boolean
	local set = neighborSets[a]
	return set ~= nil and set[b] == true
end

function Territories.GetContinent(id: number): Continent?
	return continents[id]
end

function Territories.OwnerAttribute(id: number): string
	return "Owner_" .. id
end

function Territories.TroopsAttribute(id: number): string
	return "Troops_" .. id
end

-- The folder holding the replicated state. The server creates it; clients
-- wait for it.
function Territories.State(): Folder
	if RunService:IsServer() then
		local state = ReplicatedStorage:FindFirstChild(STATE_NAME)
		if not state then
			state = Instance.new("Folder")
			state.Name = STATE_NAME
			state.Parent = ReplicatedStorage
		end
		return state :: Folder
	end
	return ReplicatedStorage:WaitForChild(STATE_NAME) :: Folder
end

-- UserId of the owner, or 0 when neutral.
function Territories.OwnerId(id: number): number
	return Territories.State():GetAttribute(Territories.OwnerAttribute(id)) or 0
end

function Territories.Troops(id: number): number
	return Territories.State():GetAttribute(Territories.TroopsAttribute(id)) or 0
end

-- The player who owns `id`, if they are still in the server.
function Territories.Owner(id: number): Player?
	local userId = Territories.OwnerId(id)
	return if userId ~= 0 then Players:GetPlayerByUserId(userId) else nil
end

-- A player's seat color, or the neutral color for nil.
function Territories.ColorOf(player: Player?): Color3
	local seat = if player then player:GetAttribute("Seat") else nil
	local config = if typeof(seat) == "number" then GameConfig.Seats[seat] else nil
	return if config then config.color.Color else GameConfig.Territories.NeutralColor
end

-- Where a territory's center is in the world, at the given height. Matches
-- the layout MapBuilder uses.
function Territories.WorldCenter(id: number, height: number): Vector3
	local t = MapData.territories[id]
	local scale = GameConfig.Map.StudsPerPixel
	return Vector3.new((t.center[1] - MapData.width / 2) * scale, height, (t.center[2] - MapData.height / 2) * scale)
end

return Territories
