--!strict
-- Builds the board in the world from MapData as a raised diorama: each
-- territory is a slab whose height follows its main terrain (mountains
-- highest, valleys lowest), with patches of its other terrains painted into
-- it, then dressed with props from Map.Props. Thin grey borders, golden
-- continent edges, rivers and sea routes go on top, and Map.Environment adds
-- the sea, the war table and the lighting.
--
-- Roblox has no polygon part, so each slab is the pre-computed triangles from
-- MapData, each drawn as two WedgeParts. Map pixels become studs on the XZ
-- plane, centred on the origin (pixel x -> +X, pixel y -> +Z).
--
-- When BoardMeshes holds the meshes imported from the Blender board
-- (tools/blender), the ground, props, gold edges and rivers come from those
-- meshes instead, and the gaps between tiles stand in for the borders.

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Environment = require(script.Parent.Map.Environment)
local Props = require(script.Parent.Map.Props)

type Territory = {
	id: number,
	name: string,
	terrains: { string },
	resources: { string },
	size: string,
	continent: number?,
	center: { number },
	outline: { number },
	triangles: { number },
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

-- A painted patch of a second terrain inside a territory.
type Zone = { kind: string, at: Vector2, radius: number, phase: number }
-- A territory's shape on the XZ plane plus what the builder works out for it.
type Plot = {
	territory: Territory,
	poly: { Vector2 },
	min: Vector2,
	max: Vector2,
	center: Vector2,
	top: number,
	area: number,
	zones: { Zone },
}

-- One imported mesh: asset ids, size, and CFrame:GetComponents().
type MeshEntry = { meshId: string, textureId: string, size: { number }, cframe: { number } }

local MapData = require(ReplicatedStorage.Shared.MapData) :: any
local data = MapData :: MapData
local BoardMeshes = require(ReplicatedStorage.Shared.BoardMeshes) :: any
local meshes = BoardMeshes :: { [string]: MeshEntry }
local config = GameConfig.Map

local SCALE = config.StudsPerPixel
local BOTTOM = config.SlabBottom
local WATER = config.WaterLevel

local MapBuilder = {}

local function toFlat(x: number, y: number): Vector2
	return Vector2.new((x - data.width / 2) * SCALE, (y - data.height / 2) * SCALE)
end

local function flatList(points: { number }): { Vector2 }
	local out = table.create(#points // 2)
	for i = 1, #points - 1, 2 do
		table.insert(out, toFlat(points[i], points[i + 1]))
	end
	return out
end

local function at3(p: Vector2, height: number): Vector3
	return Vector3.new(p.X, height, p.Y)
end

local function inside(poly: { Vector2 }, p: Vector2): boolean
	local hit = false
	local j = #poly
	for i = 1, #poly do
		local a, b = poly[i], poly[j]
		if (a.Y > p.Y) ~= (b.Y > p.Y) and p.X < (b.X - a.X) * (p.Y - a.Y) / (b.Y - a.Y) + a.X then
			hit = not hit
		end
		j = i
	end
	return hit
end

-- Distance from `p` to the nearest edge of `poly`.
local function edgeDistance(poly: { Vector2 }, p: Vector2): number
	local best = math.huge
	local j = #poly
	for i = 1, #poly do
		local a = poly[j]
		local ab = poly[i] - a
		local len2 = ab:Dot(ab)
		local t = if len2 > 0 then math.clamp((p - a):Dot(ab) / len2, 0, 1) else 0
		best = math.min(best, (a + ab * t - p).Magnitude)
		j = i
	end
	return best
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

local plots: { Plot } = {}

local function plotAt(p: Vector2): Plot?
	for _, plot in plots do
		if p.X >= plot.min.X and p.X <= plot.max.X and p.Y >= plot.min.Y and p.Y <= plot.max.Y then
			if inside(plot.poly, p) then
				return plot
			end
		end
	end
	return nil
end

-- The ground on either side of the segment p -> q, a few studs off its middle.
local function sides(p: Vector2, q: Vector2): (Plot?, Plot?, Vector2)
	local mid = (p + q) / 2
	local dir = q - p
	local normal = if dir.Magnitude > 0 then Vector2.new(-dir.Y, dir.X).Unit else Vector2.new(1, 0)
	local reach = config.SideProbe
	return plotAt(mid + normal * reach), plotAt(mid - normal * reach), normal
end

-- A flat strip along `points`. `place` gives each segment's height and a
-- sideways shift, or nil to leave the segment out.
local function strip(
	points: { Vector2 },
	width: number,
	thickness: number,
	color: Color3,
	parent: Instance,
	place: (Vector2, Vector2) -> (number?, Vector2?)
): { BasePart }
	local parts = {}
	for i = 1, #points - 1 do
		local p, q = points[i], points[i + 1]
		local length = (q - p).Magnitude
		local height, shift = place(p, q)
		if length > 0.01 and height then
			local offset = shift or Vector2.zero
			local a, b = at3(p + offset, height - thickness / 2), at3(q + offset, height - thickness / 2)
			local part = newPart("Part", color, parent)
			-- Overlap by the width so corners have no gaps.
			part.Size = Vector3.new(width, thickness, length + width * 0.5)
			part.CFrame = CFrame.lookAt((a + b) / 2, b)
			table.insert(parts, part)
		end
	end
	return parts
end

local function jitter(color: Color3, rng: Random, amount: number): Color3
	local shade = rng:NextNumber(-amount, amount)
	return if shade > 0 then color:Lerp(Color3.new(1, 1, 1), shade) else color:Lerp(Color3.new(0, 0, 0), -shade)
end

local function randomPoint(plot: Plot, rng: Random, edge: number, clear: number): Vector2?
	for _ = 1, 40 do
		local p = Vector2.new(rng:NextNumber(plot.min.X, plot.max.X), rng:NextNumber(plot.min.Y, plot.max.Y))
		if inside(plot.poly, p) and (p - plot.center).Magnitude >= clear and edgeDistance(plot.poly, p) >= edge then
			return p
		end
	end
	return nil
end

local function inZone(zone: Zone, p: Vector2): boolean
	local d = p - zone.at
	local angle = math.atan2(d.Y, d.X)
	local wobble = 1 + 0.22 * math.sin(3 * angle + zone.phase) + 0.1 * math.sin(5 * angle + zone.phase * 2)
	return d.Magnitude < zone.radius * wobble
end

local function kindAt(plot: Plot, p: Vector2): string
	for i = #plot.zones, 1, -1 do
		if inZone(plot.zones[i], p) then
			return plot.zones[i].kind
		end
	end
	return plot.territory.terrains[1]
end

local function makePlot(territory: Territory, rng: Random): Plot
	local poly = flatList(territory.outline)
	local min, max = Vector2.new(math.huge, math.huge), Vector2.new(-math.huge, -math.huge)
	for _, p in poly do
		min, max = min:Min(p), max:Max(p)
	end
	local area = 0
	local tris = territory.triangles
	for i = 1, #tris, 6 do
		local a, b, c = toFlat(tris[i], tris[i + 1]), toFlat(tris[i + 2], tris[i + 3]), toFlat(tris[i + 4], tris[i + 5])
		local ab, ac = b - a, c - a
		area += math.abs(ab.X * ac.Y - ab.Y * ac.X) / 2
	end
	local plot: Plot = {
		territory = territory,
		poly = poly,
		min = min,
		max = max,
		center = toFlat(territory.center[1], territory.center[2]),
		top = config.Elevation[territory.terrains[1]] or config.Elevation.plains,
		area = area,
		zones = {},
	}

	-- Its other terrains, then its resources, as patches away from the center.
	local wanted = {}
	for i = 2, #territory.terrains do
		table.insert(wanted, { kind = territory.terrains[i], share = config.ZoneRadius.terrain })
	end
	for _, resource in territory.resources do
		local kind = config.ResourceTerrain[resource]
		if kind and kind ~= territory.terrains[1] then
			table.insert(wanted, { kind = kind, share = config.ZoneRadius[resource] or config.ZoneRadius.terrain })
		end
	end
	local reach = math.sqrt(area / math.pi)
	for _, want in wanted do
		local radius = reach * want.share
		local at = randomPoint(plot, rng, radius * 0.5, config.CenterClear + radius * 0.6)
		if at then
			table.insert(
				plot.zones,
				{ kind = want.kind, at = at, radius = radius, phase = rng:NextNumber(0, math.pi * 2) }
			)
		end
	end
	return plot
end

local function buildSlab(plot: Plot, rng: Random, parent: Instance)
	local tris = plot.territory.triangles
	local mid = (plot.top + BOTTOM) / 2
	local ground = jitter(
		config.TerrainColors[plot.territory.terrains[1]] or config.TerrainColors.plains,
		rng,
		config.TerritoryShade
	)
	for i = 1, #tris, 6 do
		local a, b, c = toFlat(tris[i], tris[i + 1]), toFlat(tris[i + 2], tris[i + 3]), toFlat(tris[i + 4], tris[i + 5])
		triangle(at3(a, mid), at3(b, mid), at3(c, mid), plot.top - BOTTOM, ground, parent)
	end

	-- Each patch is a cluster of flat overlapping discs, each kept inside
	-- the borders, so it reads as a soft blob of another ground.
	for _, zone in plot.zones do
		local color = jitter(config.TerrainColors[zone.kind] or ground, rng, config.ColorJitter)
		for _ = 1, config.PatchDiscs do
			local angle = rng:NextNumber(0, math.pi * 2)
			local at = zone.at + Vector2.new(math.cos(angle), math.sin(angle)) * zone.radius * rng:NextNumber(0, 0.6)
			local radius = math.min(zone.radius * rng:NextNumber(0.35, 0.6), edgeDistance(plot.poly, at) - 1)
			if radius > 2 and inside(plot.poly, at) then
				local disc = newPart("Part", color, parent)
				disc.Shape = Enum.PartType.Cylinder
				disc.Size = Vector3.new(0.1, radius * 2, radius * 2)
				disc.CFrame = CFrame.new(at3(at, plot.top + 0.03)) * CFrame.Angles(0, 0, math.rad(90))
			end
		end
	end
end

-- Spreads clusters of dressing over the territory, keeping the center clear
-- for armies and a banner, and every cluster inside the borders.
local function dress(plot: Plot, rng: Random, parent: Instance)
	local placed: { { at: Vector2, radius: number } } = {}
	local sizeScale = config.PropScale[plot.territory.size] or 1

	local function fits(at: Vector2, radius: number, spacing: number): boolean
		if (at - plot.center).Magnitude < config.CenterClear + radius then
			return false
		end
		if edgeDistance(plot.poly, at) < radius * config.EdgeFit + config.EdgeMargin then
			return false
		end
		for _, other in placed do
			if (at - other.at).Magnitude < (radius + other.radius) * spacing then
				return false
			end
		end
		return true
	end

	local function put(kind: string, at: Vector2, scale: number)
		Props.dress(kind, at3(at, plot.top), rng, parent, scale)
		table.insert(placed, { at = at, radius = (Props.Footprint[kind] or 8) * scale })
	end

	local landmark = config.Landmarks[plot.territory.terrains[1]]
	if landmark and rng:NextNumber() < config.LandmarkChance then
		local radius = (Props.Footprint[landmark] or 8) * sizeScale
		for _ = 1, 30 do
			local at = randomPoint(plot, rng, radius + config.EdgeMargin, config.CenterClear + radius)
			if at and fits(at, radius, 1) then
				put(landmark, at, sizeScale)
				break
			end
		end
	end

	local tries = math.floor(plot.area / config.ScatterArea)
	for _ = 1, tries do
		local at = Vector2.new(rng:NextNumber(plot.min.X, plot.max.X), rng:NextNumber(plot.min.Y, plot.max.Y))
		if inside(plot.poly, at) then
			local kind = kindAt(plot, at)
			local scale = sizeScale * rng:NextNumber(0.85, 1.15)
			local radius = (Props.Footprint[kind] or 8) * scale
			if rng:NextNumber() < (config.PropDensity[kind] or 0.5) and fits(at, radius, config.PropSpacing) then
				put(kind, at, scale)
			end
		end
	end
end

local function label(plot: Plot, parent: Instance)
	local anchor = newPart("Part", Color3.new(1, 1, 1), parent)
	anchor.Name = "Center"
	anchor.Transparency = 1
	anchor.CanQuery = false
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = at3(plot.center, plot.top + 1)

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(120, 40)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 2000
	gui.Parent = anchor

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = `{plot.territory.id}\n{plot.territory.name}`
	text.TextScaled = true
	text.Font = Enum.Font.GothamBold
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeTransparency = 0.3
	text.Parent = gui
end

local function folder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

-- Builds the imported meshes, all at once since each one yields while it
-- loads. `placements` maps a mesh name to where it goes and how it looks.
type Placement = { parent: Instance, color: Color3?, solid: boolean, material: Enum.Material? }

local function buildMeshes(placements: { [string]: Placement })
	local pending = 0
	local done = Instance.new("BindableEvent")
	for name, place in placements do
		local entry = meshes[name]
		if not entry then
			warn(`MapBuilder: no imported mesh named {name}`)
			continue
		end
		pending += 1
		task.spawn(function()
			local fidelity = if place.solid
				then Enum.CollisionFidelity.PreciseConvexDecomposition
				else Enum.CollisionFidelity.Box
			local ok, part = pcall(function()
				return InsertService:CreateMeshPartAsync(entry.meshId, fidelity, Enum.RenderFidelity.Precise)
			end)
			if ok then
				part.Name = name
				part.Anchored = true
				part.CanCollide = place.solid
				part.CanQuery = place.solid
				part.CastShadow = true
				part.Size = Vector3.new(entry.size[1], entry.size[2], entry.size[3])
				part.CFrame = CFrame.new(table.unpack(entry.cframe))
				part.Material = place.material or Enum.Material.SmoothPlastic
				if entry.textureId ~= "" then
					part.TextureID = entry.textureId
				elseif place.color then
					part.Color = place.color
				end
				part.Parent = place.parent
			else
				warn(`MapBuilder: could not load mesh {name}: {part}`)
			end
			pending -= 1
			if pending == 0 then
				done:Fire()
			end
		end)
	end
	if pending > 0 then
		done.Event:Wait()
	end
	done:Destroy()
end

-- Part-built borders, gold edges and rivers, for when there are no meshes.
local function buildParts(map: Model)
	-- Borders sit on the higher side, so they trace the top of any cliff.
	local borders = folder("Borders", map)
	for _, line in data.borders do
		local parts = strip(flatList(line), config.BorderWidth, 0.1, config.BorderColor, borders, function(p, q)
			local a, b = sides(p, q)
			if not a and not b then
				return nil, nil
			end
			return math.max(a and a.top or WATER, b and b.top or WATER) + 0.06, nil
		end)
		for _, part in parts do
			part.Transparency = config.BorderTransparency
		end
	end

	-- Golden edges follow the continent's own ground.
	local continents = folder("Continents", map)
	for _, continent in data.continents do
		local edge = folder(string.format("Continent_%02d", continent.id), continents)
		edge:SetAttribute("ContinentId", continent.id)
		edge:SetAttribute("Name", continent.name)
		edge:SetAttribute("Bonus", continent.bonus)
		local parts = strip(
			flatList(continent.edge),
			config.ContinentEdgeWidth,
			0.3,
			config.ContinentEdgeColor,
			edge,
			function(p, q)
				local a, b = sides(p, q)
				local own = if a and a.territory.continent == continent.id then a else b
				local ground = own or a
				return (if ground then ground.top else WATER) + 0.14, nil
			end
		)
		for _, part in parts do
			part.Material = config.ContinentEdgeMaterial
			part.Reflectance = 0.15
		end
	end

	-- Rivers run at the foot of the lower bank, pushed off any cliff, over
	-- a darker bed so they read from far away. Drawn last so they sit over
	-- borders and gold edges.
	local rivers = folder("Rivers", map)
	for _, river in data.rivers do
		local width = if river.main then config.RiverWidth else config.TributaryWidth
		local function place(p: Vector2, q: Vector2): (number?, Vector2?)
			local a, b, normal = sides(p, q)
			if not a and not b then
				return WATER + 0.1, nil
			end
			local ha, hb = if a then a.top else WATER, if b then b.top else WATER
			if math.abs(ha - hb) < 0.01 then
				return ha + 0.16, nil
			end
			-- Move toward the lower side by half the width.
			local shift = normal * (width * 0.5) * (if ha < hb then 1 else -1)
			return math.min(ha, hb) + 0.16, shift
		end
		strip(flatList(river.path), width + config.RiverBankExtra, 0.3, config.RiverBankColor, rivers, function(p, q)
			local h, shift = place(p, q)
			return if h then h - 0.04 else nil, shift
		end)
		for _, part in strip(flatList(river.path), width, 0.3, config.RiverColor, rivers, place) do
			part.Material = Enum.Material.Glass
			part.Reflectance = 0.2
		end
	end
end

local function buildSeaRoutes(map: Model)
	local routes = folder("SeaRoutes", map)
	for _, route in data.seaRoutes do
		local a = at3(toFlat(route.line[1], route.line[2]), WATER + 0.3)
		local b = at3(toFlat(route.line[3], route.line[4]), WATER + 0.3)
		local steps = math.max(1, math.floor((b - a).Magnitude / 6))
		for i = 0, steps - 1, 2 do
			local p, q = a:Lerp(b, i / steps), a:Lerp(b, (i + 1) / steps)
			local dash = newPart("Part", Color3.new(1, 1, 1), routes)
			dash.Transparency = 0.15
			dash.Size = Vector3.new(1.2, 0.1, (q - p).Magnitude)
			dash.CFrame = CFrame.lookAt((p + q) / 2, q)
		end
	end
end

-- Builds the whole board into a new Model called "Map" under `parent`
-- (replacing any old one) and returns it.
function MapBuilder.build(parent: Instance): Model
	local old = parent:FindFirstChild("Map")
	if old then
		Environment.clear()
		old:Destroy()
	end

	local map = Instance.new("Model")
	map.Name = "Map"
	local rng = Random.new(config.Seed)

	table.clear(plots)
	for _, territory in data.territories do
		table.insert(plots, makePlot(territory, rng))
	end

	local useMeshes = config.UseMeshBoard and next(meshes) ~= nil
	local placements: { [string]: Placement } = {}

	local territories = folder("Territories", map)
	for _, plot in plots do
		local territory = plot.territory
		local model = Instance.new("Model")
		model.Name = string.format("Territory_%02d", territory.id)
		model:SetAttribute("Id", territory.id)
		model:SetAttribute("Name", territory.name)
		model:SetAttribute("Continent", territory.continent or 0)
		model:SetAttribute("Top", plot.top * config.WorldScale)

		local slab, props = folder("Slab", model), folder("Props", model)
		if useMeshes then
			local key = string.format("%02d", territory.id)
			placements["Ground_" .. key] = {
				parent = slab,
				color = config.TerrainColors[territory.terrains[1]] or config.TerrainColors.plains,
				solid = true,
			}
			placements["Props_" .. key] = { parent = props, solid = false }
		else
			buildSlab(plot, rng, slab)
			dress(plot, rng, props)
		end
		label(plot, model)
		model.Parent = territories
	end

	if useMeshes then
		local continents = folder("Continents", map)
		for _, continent in data.continents do
			local edge = folder(string.format("Continent_%02d", continent.id), continents)
			edge:SetAttribute("ContinentId", continent.id)
			edge:SetAttribute("Name", continent.name)
			edge:SetAttribute("Bonus", continent.bonus)
			placements[string.format("Edge_%02d", continent.id)] = {
				parent = edge,
				color = config.ContinentEdgeColor,
				solid = false,
				material = config.ContinentEdgeMaterial,
			}
		end
		local ground = folder("Ground", map)
		placements.LandBase = { parent = ground, color = config.BaseColor, solid = true }
		placements.Rivers =
			{ parent = folder("Rivers", map), color = config.RiverColor, solid = false, material = Enum.Material.Glass }
		buildMeshes(placements)
	else
		buildParts(map)
	end

	buildSeaRoutes(map)

	local coast = {}
	for _, ring in data.coast do
		table.insert(coast, flatList(ring))
	end
	Environment.build(map, coast, config.WorldScale)

	-- Everything above is at design size; shrink it about the origin so the
	-- whole board stays within the client's render distance.
	map.WorldPivot = CFrame.identity
	map:ScaleTo(config.WorldScale)
	map:SetAttribute("WorldScale", config.WorldScale)
	map.Parent = parent
	return map
end

return MapBuilder
