--!strict
-- Read-only view of the map for the rules: which territories border each
-- other and which make up each continent. Built from MapData (or any table of
-- the same shape), so the rules never touch map geometry.

export type MapData = {
	territories: { { id: number, neighbors: { number }, continent: number } },
	continents: { { id: number, territories: { number }, bonus: number } },
}

export type Continent = {
	id: number,
	territories: { number },
	bonus: number,
}

export type Board = {
	ids: { number },
	neighbors: { [number]: { [number]: true } },
	continents: { Continent },
}

local Board = {}

function Board.fromMapData(data: MapData): Board
	local ids = {}
	local neighbors: { [number]: { [number]: true } } = {}
	for _, territory in data.territories do
		table.insert(ids, territory.id)
		neighbors[territory.id] = {}
	end
	table.sort(ids)

	-- Borders are made symmetric so a one-sided entry in the data cannot let
	-- A attack B while B cannot attack A.
	for _, territory in data.territories do
		for _, other in territory.neighbors do
			assert(neighbors[other], `territory {territory.id} borders unknown territory {other}`)
			if other ~= territory.id then
				neighbors[territory.id][other] = true
				neighbors[other][territory.id] = true
			end
		end
	end

	local continents = {}
	for _, continent in data.continents do
		for _, id in continent.territories do
			assert(neighbors[id], `continent {continent.id} lists unknown territory {id}`)
		end
		table.insert(continents, {
			id = continent.id,
			territories = table.clone(continent.territories),
			bonus = continent.bonus,
		})
	end

	return { ids = ids, neighbors = neighbors, continents = continents }
end

function Board.has(board: Board, id: any): boolean
	return type(id) == "number" and board.neighbors[id] ~= nil
end

function Board.areNeighbors(board: Board, a: number, b: number): boolean
	local set = board.neighbors[a]
	return set ~= nil and set[b] == true
end

return Board
