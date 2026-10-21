--!strict
-- Builds the board in the world from MapData: one flat slab per territory,
-- thin grey borders, rivers, golden continent edges and small terrain props.
-- Roblox has no polygon part, so each slab is the pre-computed triangles from
-- MapData, each drawn as two WedgeParts.
--
-- Map pixels become studs on the XZ plane, centred on the origin
-- (pixel x -> +X, pixel y -> +Z).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

type Prop = { x: number, y: number, kind: string }
type Territory = {
	id: number,
	name: string,
	terrains: { string },
	continent: number?,
	center: { number },
	triangles: { number },
	props: { Prop },
}
type Continent = { id: number, name: string, bonus: number, edge: { number } }
type River = { name: string, main: boolean, path: { number } }
type SeaRoute = { from: number, to: number, line: { number } }
type MapData = {
	width: number,
	height: number,
	territories: { Territory },
	continents: { Continent },
	rivers: { River },
	borders: { { number } },
	coast: { { number } },
	seaRoutes: { SeaRoute },
}

local MapData = require(ReplicatedStorage.Shared.MapData) :: any
local data = MapData :: MapData
local config = GameConfig.Map

local SCALE = config.StudsPerPixel
local TOP = config.SlabThickness

local MapBuilder = {}

local function toWorld(x: number, y: number, height: number): Vector3
	return Vector3.new((x - data.width / 2) * SCALE, height, (y - data.height / 2) * SCALE)
end

local function newPart(class: string, color: Color3, parent: Instance): BasePart
	local part = Instance.new(class) :: BasePart
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = color
	part.Parent = parent
	return part
end

-- Two wedges filling the triangle a, b, c, thick along the triangle's normal.
local function triangle(a: Vector3, b: Vector3, c: Vector3, thickness: number, color: Color3, parent: Instance)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local right = ac:Cross(ab).Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))

	local w1 = newPart("WedgePart", color, parent)
	w1.CanCollide = true
	w1.Size = Vector3.new(thickness, height, math.abs(ab:Dot(back)))
	w1.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)

	local w2 = newPart("WedgePart", color, parent)
	w2.CanCollide = true
	w2.Size = Vector3.new(thickness, height, math.abs(ac:Dot(back)))
	w2.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
end

-- A flat strip along a list of x, y pixel pairs, lying at `height`.
local function strip(points: { number }, width: number, height: number, color: Color3, parent: Instance): { BasePart }
	local parts = {}
	for i = 1, #points - 3, 2 do
		local p = toWorld(points[i], points[i + 1], height)
		local q = toWorld(points[i + 2], points[i + 3], height)
		local length = (q - p).Magnitude
		if length > 0.01 then
			local part = newPart("Part", color, parent)
			-- Overlap by the width so corners have no gaps.
			part.Size = Vector3.new(width, 0.1, length + width * 0.5)
			part.CFrame = CFrame.lookAt((p + q) / 2, q)
			table.insert(parts, part)
		end
	end
	return parts
end

local PROP_COLORS = {
	rock = Color3.fromHex("8c7b66"),
	mesa = Color3.fromHex("c09a66"),
	sand = Color3.fromHex("dcc283"),
	trunk = Color3.fromHex("5b4630"),
	leaves = Color3.fromHex("4e8c46"),
	water = Color3.fromHex("6db7d4"),
}

local function prop(kind: string, at: Vector3, rng: Random, parent: Instance)
	if kind == "peak" then
		for i = 1, 3 do
			local size = (i == 1 and 7 or 4.5) * rng:NextNumber(0.85, 1.15)
			local offset = if i == 1
				then Vector3.zero
				else Vector3.new((i == 2 and -1 or 1) * 4.5, 0, rng:NextNumber(-1.5, 1.5))
			local rock = newPart("Part", PROP_COLORS.rock, parent)
			rock.Size = Vector3.new(size, size, size)
			-- Corner pointing up, half sunk into the slab.
			rock.CFrame = CFrame.new(at + offset + Vector3.new(0, size * 0.3, 0))
				* CFrame.Angles(0, rng:NextNumber(0, math.pi), 0)
				* CFrame.Angles(math.rad(45), 0, math.rad(35.26))
		end
	elseif kind == "mesa" then
		local mesa = newPart("Part", PROP_COLORS.mesa, parent)
		mesa.Shape = Enum.PartType.Cylinder
		mesa.Size = Vector3.new(4, 11, 11)
		mesa.CFrame = CFrame.new(at + Vector3.new(0, 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	elseif kind == "dune" then
		for i = -1, 1, 2 do
			local dune = newPart("Part", PROP_COLORS.sand, parent)
			dune.Shape = Enum.PartType.Cylinder
			dune.Size = Vector3.new(10, 3, 3)
			dune.CFrame = CFrame.new(at + Vector3.new(i * 1.5, 0, i * 2.5)) * CFrame.Angles(0, math.rad(20), 0)
		end
	elseif kind == "grove" then
		for i = 1, 3 do
			local angle = i * math.pi * 2 / 3 + rng:NextNumber(0, 0.5)
			local base = at + Vector3.new(math.cos(angle) * 3, 0, math.sin(angle) * 3)
			local trunk = newPart("Part", PROP_COLORS.trunk, parent)
			trunk.Size = Vector3.new(0.8, 3, 0.8)
			trunk.Position = base + Vector3.new(0, 1.5, 0)
			local leaves = newPart("Part", PROP_COLORS.leaves, parent)
			leaves.Shape = Enum.PartType.Ball
			local size = rng:NextNumber(3.5, 4.5)
			leaves.Size = Vector3.new(size, size, size)
			leaves.Position = base + Vector3.new(0, 3 + size * 0.35, 0)
		end
	elseif kind == "pond" or kind == "pond_big" then
		local size = if kind == "pond_big" then 20 else 12
		local pond = newPart("Part", PROP_COLORS.water, parent)
		pond.Shape = Enum.PartType.Cylinder
		pond.Size = Vector3.new(0.2, size, size * 0.7)
		pond.CFrame = CFrame.new(at + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90))
	end
end

local function label(territory: Territory, parent: Instance)
	local anchor = newPart("Part", Color3.new(1, 1, 1), parent)
	anchor.Name = "Center"
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = toWorld(territory.center[1], territory.center[2], TOP + 1)

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(120, 40)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 2000
	gui.Parent = anchor

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = `{territory.id}\n{territory.name}`
	text.TextScaled = true
	text.Font = Enum.Font.GothamBold
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeTransparency = 0.3
	text.Parent = gui
end

-- Builds the whole board into a new Model called "Map" under `parent`
-- (replacing any old one) and returns it.
function MapBuilder.build(parent: Instance): Model
	local old = parent:FindFirstChild("Map")
	if old then
		old:Destroy()
	end

	local map = Instance.new("Model")
	map.Name = "Map"
	local rng = Random.new(7)

	local width, depth = data.width * SCALE, data.height * SCALE
	local ocean = newPart("Part", config.DeepSeaColor, map)
	ocean.Name = "Ocean"
	ocean.Size = Vector3.new(width, 1, depth)
	ocean.Position = Vector3.new(0, -0.5, 0)
	ocean.CanCollide = true

	-- Lighter shallow water along every coast, half hidden under the land.
	local shallows = Instance.new("Folder")
	shallows.Name = "Shallows"
	shallows.Parent = map
	for _, ring in data.coast do
		strip(ring, 40, 0.05, config.ShallowSeaColor, shallows)
	end

	local territories = Instance.new("Folder")
	territories.Name = "Territories"
	territories.Parent = map
	for _, territory in data.territories do
		local model = Instance.new("Model")
		model.Name = string.format("Territory_%02d", territory.id)
		model:SetAttribute("Id", territory.id)
		model:SetAttribute("Name", territory.name)
		model:SetAttribute("Continent", territory.continent or 0)

		local color = config.TerrainColors[territory.terrains[1]] or config.TerrainColors.plains
		local slab = Instance.new("Folder")
		slab.Name = "Slab"
		slab.Parent = model
		local tris = territory.triangles
		for i = 1, #tris, 6 do
			triangle(
				toWorld(tris[i], tris[i + 1], TOP / 2),
				toWorld(tris[i + 2], tris[i + 3], TOP / 2),
				toWorld(tris[i + 4], tris[i + 5], TOP / 2),
				TOP,
				color,
				slab
			)
		end

		local props = Instance.new("Folder")
		props.Name = "Props"
		props.Parent = model
		for _, p in territory.props do
			prop(p.kind, toWorld(p.x, p.y, TOP), rng, props)
		end

		label(territory, model)
		model.Parent = territories
	end

	local borders = Instance.new("Folder")
	borders.Name = "Borders"
	borders.Parent = map
	for _, line in data.borders do
		for _, part in strip(line, config.BorderWidth, TOP + 0.05, config.BorderColor, borders) do
			part.Transparency = config.BorderTransparency
		end
	end

	local continents = Instance.new("Folder")
	continents.Name = "Continents"
	continents.Parent = map
	for _, continent in data.continents do
		local folder = Instance.new("Folder")
		folder.Name = string.format("Continent_%02d", continent.id)
		folder:SetAttribute("ContinentId", continent.id)
		folder:SetAttribute("Name", continent.name)
		folder:SetAttribute("Bonus", continent.bonus)
		folder.Parent = continents
		strip(continent.edge, config.ContinentEdgeWidth, TOP + 0.1, config.ContinentEdgeColor, folder)
	end

	-- Rivers last so they sit over borders and gold edges.
	local rivers = Instance.new("Folder")
	rivers.Name = "Rivers"
	rivers.Parent = map
	for _, river in data.rivers do
		local width = if river.main then config.RiverWidth else config.TributaryWidth
		strip(river.path, width, TOP + 0.15, config.RiverColor, rivers)
	end

	local routes = Instance.new("Folder")
	routes.Name = "SeaRoutes"
	routes.Parent = map
	for _, route in data.seaRoutes do
		local a = toWorld(route.line[1], route.line[2], 0.2)
		local b = toWorld(route.line[3], route.line[4], 0.2)
		local steps = math.max(1, math.floor((b - a).Magnitude / 6))
		for i = 0, steps - 1, 2 do
			local p, q = a:Lerp(b, i / steps), a:Lerp(b, (i + 1) / steps)
			local dash = newPart("Part", Color3.new(1, 1, 1), routes)
			dash.Transparency = 0.25
			dash.Size = Vector3.new(1, 0.1, (q - p).Magnitude)
			dash.CFrame = CFrame.lookAt((p + q) / 2, q)
		end
	end

	map.Parent = parent
	return map
end

return MapBuilder
