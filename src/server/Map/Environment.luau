--!strict
-- The world around the board: a Terrain sea with a turquoise shelf along every
-- coast, a dark lacquered war table framing the sea, golden-hour lighting and a
-- few junk boats. build() and clear() are safe to call repeatedly.
--
-- Board contract: the sea opening is X in [-SeaHalfX, SeaHalfX], Z in
-- [-SeaHalfZ, SeaHalfZ], water surface at Y = 0. Coast rings come in world studs.

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local STYLE = {
	-- Sea opening (inner edge of the table) and how far the water runs under the rim.
	SeaHalfX = 768,
	SeaHalfZ = 512,
	WaterUnderRim = 16,
	WaterLevel = 0,
	VoxelSize = 4,
	ChunkColumns = 49, -- voxel columns along X written per frame

	-- Seabed profile by distance from the nearest coast (studs).
	BedBottom = -20, -- bottom of the terrain slab
	ShelfTop = -0.6, -- seabed height right at the coast
	ShelfEdge = -4.6, -- seabed height at the end of the shelf
	ShelfReach = 38,
	DropReach = 40, -- slope from the shelf edge down to the deep floor
	DeepFloor = -14,
	BedNoise = 1.2, -- +- studs of gentle bumps on the seabed
	BedNoiseScale = 70,
	-- Seabed colour bands by distance from the coast; terrain blends between them,
	-- so the shallows fade from pale aqua to deep blue.
	BedBands = {
		{ reach = 12, material = Enum.Material.Sand, color = Color3.fromRGB(176, 228, 206) },
		{ reach = 24, material = Enum.Material.Limestone, color = Color3.fromRGB(112, 202, 194) },
		{ reach = 40, material = Enum.Material.Ground, color = Color3.fromRGB(56, 150, 164) },
		{ reach = 58, material = Enum.Material.Slate, color = Color3.fromRGB(30, 92, 124) },
		{ reach = math.huge, material = Enum.Material.Mud, color = Color3.fromRGB(12, 36, 62) },
	} :: { { reach: number, material: Enum.Material, color: Color3 } },

	Water = {
		Color = Color3.fromRGB(14, 72, 118),
		Transparency = 0.62,
		Reflectance = 0.18,
		WaveSize = 0.05,
		WaveSpeed = 6,
	},

	-- War table, measured outward from the sea edge.
	Table = {
		ChamferWidth = 6, -- inner bevel from the water up to the rim top
		RimTop = 4,
		BoardWidth = 26, -- flat rim top after the chamfer
		BoardBottom = -6,
		InlayInset = 7, -- red lacquer band inset from the board's inner edge
		InlayWidth = 11,
		OuterBevel = 6,
		BodyBottom = -8,
		ApronInset = 2, -- apron face is set back from the rim's outer face
		ApronBottom = -30,
		FootBottom = -36,
		FootOut = 2, -- bottom moulding sticks out past the rim
		TrimWidth = 1.5,
		TrimHeight = 0.3,
		StudSpacing = 128,
		StudSize = 3,
		MedallionSize = 15,
		PillarSize = 46,
		PillarTop = 7,
		PillarBottom = -40,
		PearlSize = 13, -- gold finial ball on each corner pillar
		LegSize = 36,
		FootSize = 46,
		FloorY = -160,
		RailY = -130,
		RailSize = 9,
		PlateThickness = 4,
	},
	Wood = Color3.fromRGB(58, 34, 22),
	WoodDark = Color3.fromRGB(38, 22, 15),
	WoodTop = Color3.fromRGB(74, 44, 27),
	Lacquer = Color3.fromRGB(122, 28, 22),
	Gold = Color3.fromRGB(212, 168, 76),
	Jade = Color3.fromRGB(70, 150, 112),
	Floor = Color3.fromRGB(30, 27, 25),
	FloorHalf = 2048,
	Rug = Color3.fromRGB(108, 26, 24),
	RugMargin = 150, -- rug overhang past the table's footprint
	RugBorder = 18,

	Boats = {
		Count = 9,
		Seed = 1949,
		MinCoast = 26, -- studs of clear water to the nearest coast
		MinSpacing = 150,
		Inset = 40, -- keep away from the table edge
		Scale = 1,
		Hull = Color3.fromRGB(96, 62, 36),
		Deck = Color3.fromRGB(168, 124, 76),
		Sail = Color3.fromRGB(186, 70, 44),
		Mast = Color3.fromRGB(52, 34, 22),
		Wake = Color3.fromRGB(235, 248, 250),
		WakeTransparency = 0.45,
	},

	Light = {
		ClockTime = 15.6,
		GeographicLatitude = 32,
		Brightness = 2.6,
		Ambient = Color3.fromRGB(78, 70, 64),
		OutdoorAmbient = Color3.fromRGB(150, 140, 128),
		ColorShiftTop = Color3.fromRGB(255, 238, 210),
		ColorShiftBottom = Color3.fromRGB(0, 0, 0),
		EnvironmentDiffuseScale = 0.45,
		EnvironmentSpecularScale = 0.6,
		ShadowSoftness = 0.3,
		ExposureCompensation = 0,
		AtmosphereDensity = 0.18,
		AtmosphereOffset = 0.08,
		AtmosphereColor = Color3.fromRGB(214, 200, 178),
		AtmosphereDecay = Color3.fromRGB(128, 108, 86),
		AtmosphereGlare = 0.05,
		AtmosphereHaze = 0.4,
		BloomIntensity = 0.3,
		BloomSize = 20,
		BloomThreshold = 1.7,
		Saturation = 0.14,
		Contrast = 0.08,
		CorrectionBrightness = 0.01,
		Tint = Color3.fromRGB(255, 249, 240),
		SunRaysIntensity = 0.035,
		SunRaysSpread = 0.55,
	},
}

local Environment = {}

local builtFolder: Folder? = nil

type Segment = { a: Vector2, b: Vector2 }

local function waterHalf(): (number, number)
	return STYLE.SeaHalfX + STYLE.WaterUnderRim, STYLE.SeaHalfZ + STYLE.WaterUnderRim
end

local function smoothstep(t: number): number
	local c = math.clamp(t, 0, 1)
	return c * c * (3 - 2 * c)
end

local function segments(coast: { { Vector2 } }): { Segment }
	local list = {}
	for _, ring in coast do
		local count = #ring
		for i = 1, count do
			local a, b = ring[i], ring[i % count + 1]
			if (b - a).Magnitude > 0.01 then
				table.insert(list, { a = a, b = b })
			end
		end
	end
	return list
end

-- Even-odd test against every coast ring: true when the point is on land.
local function onLand(coast: { { Vector2 } }, p: Vector2): boolean
	local inside = false
	for _, ring in coast do
		local count = #ring
		local j = count
		for i = 1, count do
			local a, b = ring[i], ring[j]
			if (a.Y > p.Y) ~= (b.Y > p.Y) and p.X < (b.X - a.X) * (p.Y - a.Y) / (b.Y - a.Y) + a.X then
				inside = not inside
			end
			j = i
		end
	end
	return inside
end

-- Distance (studs) from each voxel column centre to the nearest coast segment,
-- capped at the shelf + drop reach. Flat array indexed ix * nz + iz + 1.
local function distanceField(segs: { Segment }, nx: number, nz: number): { number }
	local size = STYLE.VoxelSize
	local halfX, halfZ = waterHalf()
	local reach = STYLE.ShelfReach + STYLE.DropReach
	local field = table.create(nx * nz, reach)
	for n, seg in segs do
		local a, b = seg.a, seg.b
		local ab = b - a
		local len2 = ab:Dot(ab)
		local x0 = math.clamp(math.floor((math.min(a.X, b.X) - reach + halfX) / size), 0, nx - 1)
		local x1 = math.clamp(math.floor((math.max(a.X, b.X) + reach + halfX) / size), 0, nx - 1)
		local z0 = math.clamp(math.floor((math.min(a.Y, b.Y) - reach + halfZ) / size), 0, nz - 1)
		local z1 = math.clamp(math.floor((math.max(a.Y, b.Y) + reach + halfZ) / size), 0, nz - 1)
		for ix = x0, x1 do
			local px = -halfX + (ix + 0.5) * size
			for iz = z0, z1 do
				local pz = -halfZ + (iz + 0.5) * size
				local t = math.clamp(((px - a.X) * ab.X + (pz - a.Y) * ab.Y) / len2, 0, 1)
				local dx, dz = px - (a.X + ab.X * t), pz - (a.Y + ab.Y * t)
				local d = math.sqrt(dx * dx + dz * dz)
				local index = ix * nz + iz + 1
				if d < field[index] then
					field[index] = d
				end
			end
		end
		if n % 150 == 0 then
			task.wait()
		end
	end
	return field
end

local function bedHeight(d: number, x: number, z: number): number
	local h
	if d <= STYLE.ShelfReach then
		h = STYLE.ShelfTop + (STYLE.ShelfEdge - STYLE.ShelfTop) * (d / STYLE.ShelfReach)
	else
		h = STYLE.ShelfEdge + (STYLE.DeepFloor - STYLE.ShelfEdge) * smoothstep((d - STYLE.ShelfReach) / STYLE.DropReach)
	end
	local bump = math.noise(x / STYLE.BedNoiseScale, z / STYLE.BedNoiseScale, 3.7) * STYLE.BedNoise
	-- Bumps fade out towards the coast so the beach line stays clean.
	return math.min(h + bump * smoothstep(d / STYLE.ShelfReach), STYLE.WaterLevel - 0.5)
end

local function bedMaterial(d: number): Enum.Material
	for _, band in STYLE.BedBands do
		if d < band.reach then
			return band.material
		end
	end
	return STYLE.BedBands[#STYLE.BedBands].material
end

local function buildSea(coast: { { Vector2 } })
	local terrain = Workspace.Terrain
	terrain.WaterColor = STYLE.Water.Color
	terrain.WaterTransparency = STYLE.Water.Transparency
	terrain.WaterReflectance = STYLE.Water.Reflectance
	terrain.WaterWaveSize = STYLE.Water.WaveSize
	terrain.WaterWaveSpeed = STYLE.Water.WaveSpeed
	for _, band in STYLE.BedBands do
		terrain:SetMaterialColor(band.material, band.color)
	end

	local size = STYLE.VoxelSize
	local halfX, halfZ = waterHalf()
	local nx, nz = math.floor(halfX * 2 / size), math.floor(halfZ * 2 / size)
	local ny = math.floor((STYLE.WaterLevel - STYLE.BedBottom) / size)
	local field = distanceField(segments(coast), nx, nz)
	task.wait()

	local anyTerrain = terrain :: any
	for cx = 0, nx - 1, STYLE.ChunkColumns do
		local count = math.min(STYLE.ChunkColumns, nx - cx)
		local materials, solids, liquids = {}, {}, {}
		for ix = 1, count do
			local column = cx + ix - 1
			local px = -halfX + (column + 0.5) * size
			local matX, solidX, liquidX = {}, {}, {}
			for iy = 1, ny do
				matX[iy], solidX[iy], liquidX[iy] = {}, {}, {}
			end
			for iz = 1, nz do
				local pz = -halfZ + (iz - 0.5) * size
				local d = field[column * nz + iz]
				local h = bedHeight(d, px, pz)
				local material = bedMaterial(d)
				for iy = 1, ny do
					local y0 = STYLE.BedBottom + (iy - 1) * size
					local solid = math.clamp((h - y0) / size, 0, 1)
					matX[iy][iz] = material
					solidX[iy][iz] = solid
					liquidX[iy][iz] = 1 - solid
				end
			end
			materials[ix], solids[ix], liquids[ix] = matX, solidX, liquidX
		end
		local region = Region3.new(
			Vector3.new(-halfX + cx * size, STYLE.BedBottom, -halfZ),
			Vector3.new(-halfX + (cx + count) * size, STYLE.WaterLevel, halfZ)
		)
		anyTerrain:WriteVoxelChannels(region, size, {
			SolidMaterial = materials,
			SolidOccupancy = solids,
			LiquidOccupancy = liquids,
		})
		task.wait()
	end
end

local function newPart(class: string, color: Color3, material: Enum.Material, parent: Instance): BasePart
	local part = Instance.new(class) :: BasePart
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = color
	part.Parent = parent
	return part
end

local function block(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material
): BasePart
	local part = newPart("Part", color, material, parent)
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	return part
end

-- A wedge whose low edge faces `facing` (a unit XZ direction).
local function wedge(
	parent: Instance,
	name: string,
	size: Vector3,
	center: Vector3,
	facing: Vector3,
	color: Color3,
	material: Enum.Material
): BasePart
	local part = newPart("WedgePart", color, material, parent)
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.lookAt(center, center + facing)
	return part
end

local function disc(parent: Instance, name: string, diameter: number, thickness: number, at: Vector3, color: Color3)
	local part = newPart("Part", color, Enum.Material.Metal, parent)
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(thickness, diameter, diameter)
	part.CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90))
	return part
end

-- One side of the table. `out` is the outward unit direction, `edge` the
-- distance from the origin to the sea edge on this side and `length` the side's
-- length between the corner pillars.
local function tableSide(parent: Instance, out: Vector3, edge: number, length: number)
	local T = STYLE.Table
	local horizontal = math.abs(out.Z) > 0.5 -- the side runs along X
	local function at(offset: number, y: number): Vector3
		return out * (edge + offset) + Vector3.new(0, y, 0)
	end
	local function sized(across: number, height: number): Vector3
		return if horizontal then Vector3.new(length, height, across) else Vector3.new(across, height, length)
	end
	local function wedgeSize(across: number, height: number): Vector3
		return Vector3.new(length, height, across)
	end

	local chamfer = T.ChamferWidth
	local boardOuter = chamfer + T.BoardWidth
	local rimOuter = boardOuter + T.OuterBevel
	local rimHeight = T.RimTop - T.BoardBottom

	-- Inner chamfer rises from just under the water to the rim top.
	local c = wedge(
		parent,
		"InnerBevel",
		wedgeSize(chamfer, T.RimTop + 1),
		at(chamfer / 2, (T.RimTop - 1) / 2),
		-out,
		STYLE.Wood,
		Enum.Material.Wood
	)
	c.CastShadow = false

	local board = block(
		parent,
		"RimTop",
		sized(T.BoardWidth, rimHeight),
		CFrame.new(at(chamfer + T.BoardWidth / 2, T.BoardBottom + rimHeight / 2)),
		STYLE.WoodTop,
		Enum.Material.WoodPlanks
	)
	board.CanCollide = true

	block(
		parent,
		"GoldTrim",
		sized(T.TrimWidth, T.TrimHeight),
		CFrame.new(at(chamfer + T.TrimWidth / 2, T.RimTop + T.TrimHeight / 2)),
		STYLE.Gold,
		Enum.Material.Metal
	)
	block(
		parent,
		"LacquerBand",
		sized(T.InlayWidth, 0.12),
		CFrame.new(at(chamfer + T.InlayInset + T.InlayWidth / 2, T.RimTop + 0.06)),
		STYLE.Lacquer,
		Enum.Material.SmoothPlastic
	)
	local bandMid = chamfer + T.InlayInset + T.InlayWidth / 2
	for _, side in { -1, 1 } do
		block(
			parent,
			"LacquerEdge",
			sized(0.8, 0.16),
			CFrame.new(at(bandMid + side * (T.InlayWidth / 2 + 0.4), T.RimTop + 0.08)),
			STYLE.Gold,
			Enum.Material.Metal
		)
	end

	wedge(
		parent,
		"OuterBevel",
		wedgeSize(T.OuterBevel, T.RimTop),
		at(boardOuter + T.OuterBevel / 2, T.RimTop / 2),
		out,
		STYLE.Wood,
		Enum.Material.Wood
	)
	block(
		parent,
		"Body",
		sized(T.OuterBevel + 2, -T.BodyBottom),
		CFrame.new(at(rimOuter - (T.OuterBevel + 2) / 2, T.BodyBottom / 2)),
		STYLE.Wood,
		Enum.Material.Wood
	)
	block(
		parent,
		"GoldBand",
		sized(0.6, 1.2),
		CFrame.new(at(rimOuter + 0.3, T.BodyBottom + 1.6)),
		STYLE.Gold,
		Enum.Material.Metal
	)
	local apronFace = rimOuter - T.ApronInset
	block(
		parent,
		"Apron",
		sized(apronFace - 2, T.BodyBottom - T.ApronBottom),
		CFrame.new(at(2 + (apronFace - 2) / 2, (T.BodyBottom + T.ApronBottom) / 2)),
		STYLE.WoodDark,
		Enum.Material.Wood
	)
	local footFace = rimOuter + T.FootOut
	block(
		parent,
		"FootMoulding",
		sized(footFace - 2, T.ApronBottom - T.FootBottom),
		CFrame.new(at(2 + (footFace - 2) / 2, (T.ApronBottom + T.FootBottom) / 2)),
		STYLE.Wood,
		Enum.Material.Wood
	)
	block(
		parent,
		"FootTrim",
		sized(0.6, 0.8),
		CFrame.new(at(footFace + 0.3, T.ApronBottom - 1)),
		STYLE.Gold,
		Enum.Material.Metal
	)

	-- Gold studs along the lacquer band and a jade medallion mid-side.
	local along = if horizontal then Vector3.new(1, 0, 0) else Vector3.new(0, 0, 1)
	local bandCenter = at(bandMid, T.RimTop + 0.2)
	local studs = math.floor(length / T.StudSpacing)
	for i = 1, studs - 1 do
		local offset = -length / 2 + i * (length / studs)
		if math.abs(offset) > T.MedallionSize then
			disc(parent, "Stud", T.StudSize, 0.4, bandCenter + along * offset, STYLE.Gold)
		end
	end
	disc(parent, "Medallion", T.MedallionSize, 0.5, bandCenter, STYLE.Gold)
	local jade = disc(parent, "MedallionJade", T.MedallionSize * 0.62, 0.7, bandCenter, STYLE.Jade)
	jade.Material = Enum.Material.Glass
end

local function corner(parent: Instance, sx: number, sz: number)
	local T = STYLE.Table
	local s = T.PillarSize
	local cx, cz = sx * (STYLE.SeaHalfX + s / 2), sz * (STYLE.SeaHalfZ + s / 2)
	local function at(y: number): CFrame
		return CFrame.new(cx, y, cz)
	end
	local pillarHeight = T.PillarTop - T.PillarBottom
	local pillar = block(
		parent,
		"CornerPillar",
		Vector3.new(s, pillarHeight, s),
		at(T.PillarBottom + pillarHeight / 2),
		STYLE.Wood,
		Enum.Material.Wood
	)
	pillar.CanCollide = true
	block(parent, "CornerPlate", Vector3.new(s - 2, 1, s - 2), at(T.PillarTop + 0.5), STYLE.Gold, Enum.Material.Metal)
	block(
		parent,
		"CornerLacquer",
		Vector3.new(s * 0.62, 6, s * 0.62),
		at(T.PillarTop + 4),
		STYLE.Lacquer,
		Enum.Material.SmoothPlastic
	)
	block(
		parent,
		"CornerCap",
		Vector3.new(s * 0.72, 1.2, s * 0.72),
		at(T.PillarTop + 7.6),
		STYLE.Gold,
		Enum.Material.Metal
	)
	local pearl = newPart("Part", STYLE.Gold, Enum.Material.Metal, parent)
	pearl.Name = "CornerPearl"
	pearl.Shape = Enum.PartType.Ball
	pearl.Size = Vector3.one * T.PearlSize
	pearl.CFrame = at(T.PillarTop + 8.2 + T.PearlSize * 0.4)
	block(
		parent,
		"CornerBand",
		Vector3.new(s + 0.6, 1.2, s + 0.6),
		at(T.BodyBottom + 1.6),
		STYLE.Gold,
		Enum.Material.Metal
	)

	-- Leg and foot under the pillar.
	local legTop, legBottom = T.PillarBottom, T.FloorY + 8
	block(
		parent,
		"Leg",
		Vector3.new(T.LegSize, legTop - legBottom, T.LegSize),
		at((legTop + legBottom) / 2),
		STYLE.WoodDark,
		Enum.Material.Wood
	)
	block(
		parent,
		"LegBand",
		Vector3.new(T.LegSize + 1, 3, T.LegSize + 1),
		at(legTop - 14),
		STYLE.Gold,
		Enum.Material.Metal
	)
	block(parent, "Foot", Vector3.new(T.FootSize, 8, T.FootSize), at(T.FloorY + 4), STYLE.Wood, Enum.Material.Wood)
end

local function buildTable(parent: Instance)
	local T = STYLE.Table
	local hx, hz = STYLE.SeaHalfX, STYLE.SeaHalfZ
	for _, sign in { -1, 1 } do
		tableSide(parent, Vector3.new(0, 0, sign), hz, hx * 2)
		tableSide(parent, Vector3.new(sign, 0, 0), hx, hz * 2)
	end
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			corner(parent, sx, sz)
		end
	end

	-- Middle legs on the long sides.
	local midZ = hz + T.PillarSize / 2
	for _, sz in { -1, 1 } do
		local legTop, legBottom = T.FootBottom, T.FloorY + 8
		block(
			parent,
			"Leg",
			Vector3.new(T.LegSize, legTop - legBottom, T.LegSize),
			CFrame.new(0, (legTop + legBottom) / 2, sz * midZ),
			STYLE.WoodDark,
			Enum.Material.Wood
		)
		block(
			parent,
			"Foot",
			Vector3.new(T.FootSize, 8, T.FootSize),
			CFrame.new(0, T.FloorY + 4, sz * midZ),
			STYLE.Wood,
			Enum.Material.Wood
		)
	end

	-- Low stretcher rails joining the legs.
	local railX, railZ = hx + T.PillarSize / 2, hz + T.PillarSize / 2
	for _, sign in { -1, 1 } do
		block(
			parent,
			"Rail",
			Vector3.new(hx * 2, T.RailSize, T.RailSize),
			CFrame.new(0, T.RailY, sign * railZ),
			STYLE.WoodDark,
			Enum.Material.Wood
		)
		block(
			parent,
			"Rail",
			Vector3.new(T.RailSize, T.RailSize, hz * 2),
			CFrame.new(sign * railX, T.RailY, 0),
			STYLE.WoodDark,
			Enum.Material.Wood
		)
	end

	-- Underside board closing the terrain slab.
	local outer = T.ChamferWidth + T.BoardWidth + T.OuterBevel
	block(
		parent,
		"Underside",
		Vector3.new((hx + outer) * 2, T.PlateThickness, (hz + outer) * 2),
		CFrame.new(0, STYLE.BedBottom - T.PlateThickness / 2, 0),
		STYLE.WoodDark,
		Enum.Material.Wood
	)

	-- Hall floor and a crimson rug with a gold border under the table.
	local half = STYLE.FloorHalf
	for _, sign in { -1, 1 } do
		block(
			parent,
			"Floor",
			Vector3.new(half, 4, half),
			CFrame.new(sign * half / 2, T.FloorY - 2, 0),
			STYLE.Floor,
			Enum.Material.Slate
		)
	end
	local rugX, rugZ = hx + outer + STYLE.RugMargin, hz + outer + STYLE.RugMargin
	block(
		parent,
		"Rug",
		Vector3.new(rugX * 2, 0.4, rugZ * 2),
		CFrame.new(0, T.FloorY + 0.2, 0),
		STYLE.Rug,
		Enum.Material.Fabric
	)
	local b = STYLE.RugBorder
	local inset = 30
	for _, sign in { -1, 1 } do
		block(
			parent,
			"RugBorder",
			Vector3.new((rugX - inset) * 2, 0.5, b),
			CFrame.new(0, T.FloorY + 0.25, sign * (rugZ - inset)),
			STYLE.Gold,
			Enum.Material.Fabric
		)
		block(
			parent,
			"RugBorder",
			Vector3.new(b, 0.5, (rugZ - inset) * 2),
			CFrame.new(sign * (rugX - inset), T.FloorY + 0.25, 0),
			STYLE.Gold,
			Enum.Material.Fabric
		)
	end
end

local function junk(parent: Instance, at: Vector3, heading: number)
	local B = STYLE.Boats
	local k = B.Scale
	local model = Instance.new("Model")
	model.Name = "Junk"
	local base = CFrame.new(at) * CFrame.Angles(0, heading, 0)
	local function put(part: BasePart, size: Vector3, offset: CFrame)
		part.Size = size * k
		part.CFrame = base * CFrame.new(offset.Position * k) * offset.Rotation
	end

	put(newPart("Part", B.Hull, Enum.Material.Wood, model), Vector3.new(5, 2.2, 12), CFrame.new(0, 0.2, 0))
	-- Raised prow (forward is -Z) and a tall stern castle.
	put(
		newPart("WedgePart", B.Hull, Enum.Material.Wood, model),
		Vector3.new(5, 2.6, 4),
		CFrame.new(0, 0.4, -8) * CFrame.Angles(0, math.pi, 0) * CFrame.Angles(math.pi, 0, 0)
	)
	put(newPart("Part", B.Hull, Enum.Material.Wood, model), Vector3.new(5.4, 2.4, 3.6), CFrame.new(0, 2.2, 4.6))
	put(newPart("Part", B.Deck, Enum.Material.WoodPlanks, model), Vector3.new(4.4, 0.2, 11), CFrame.new(0, 1.35, -0.4))

	local masts = { { z = -3.6, h = 9, w = 5.5 }, { z = 0.4, h = 12, w = 7.5 }, { z = 3.8, h = 8, w = 4.5 } }
	for _, m in masts do
		put(
			newPart("Part", B.Mast, Enum.Material.Wood, model),
			Vector3.new(0.45, m.h, 0.45),
			CFrame.new(0, 1.3 + m.h / 2, m.z)
		)
		local sail = newPart("Part", B.Sail, Enum.Material.Fabric, model)
		put(
			sail,
			Vector3.new(m.w, m.h * 0.72, 0.2),
			CFrame.new(0.6, 1.3 + m.h * 0.58, m.z - 0.3) * CFrame.Angles(0, math.rad(22), 0)
		)
	end
	put(newPart("Part", B.Sail, Enum.Material.Fabric, model), Vector3.new(0.1, 1, 2), CFrame.new(0, 14.2, 1.4))

	local wake = newPart("WedgePart", B.Wake, Enum.Material.SmoothPlastic, model)
	wake.Transparency = B.WakeTransparency
	wake.CastShadow = false
	put(wake, Vector3.new(4, 0.1, 14), CFrame.new(0, 0.12, 13) * CFrame.Angles(0, math.pi, 0))
	model.Parent = parent
end

local function buildBoats(parent: Instance, coast: { { Vector2 } })
	local B = STYLE.Boats
	local segs = segments(coast)
	local rng = Random.new(B.Seed)
	local placed: { Vector2 } = {}
	local function coastDistance(p: Vector2): number
		local best = math.huge
		for _, seg in segs do
			local ab = seg.b - seg.a
			local t = math.clamp((p - seg.a):Dot(ab) / ab:Dot(ab), 0, 1)
			best = math.min(best, (p - (seg.a + ab * t)).Magnitude)
		end
		return best
	end
	local limitX, limitZ = STYLE.SeaHalfX - B.Inset, STYLE.SeaHalfZ - B.Inset
	for _ = 1, 600 do
		if #placed >= B.Count then
			break
		end
		local p = Vector2.new(rng:NextNumber(-limitX, limitX), rng:NextNumber(-limitZ, limitZ))
		local clear = true
		for _, other in placed do
			if (other - p).Magnitude < B.MinSpacing then
				clear = false
				break
			end
		end
		if clear and not onLand(coast, p) and coastDistance(p) >= B.MinCoast * B.Scale then
			table.insert(placed, p)
			junk(parent, Vector3.new(p.X, STYLE.WaterLevel, p.Y), rng:NextNumber(0, math.pi * 2))
		end
	end
end

local function effect(className: string, name: string): Instance
	local old = Lighting:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = Lighting
	return instance
end

local function buildLighting()
	local L = STYLE.Light
	pcall(function()
		(Lighting :: any).Technology = Enum.Technology.Future
	end)
	Lighting.ClockTime = L.ClockTime
	Lighting.GeographicLatitude = L.GeographicLatitude
	Lighting.Brightness = L.Brightness
	Lighting.Ambient = L.Ambient
	Lighting.OutdoorAmbient = L.OutdoorAmbient
	Lighting.ColorShift_Top = L.ColorShiftTop
	Lighting.ColorShift_Bottom = L.ColorShiftBottom
	Lighting.EnvironmentDiffuseScale = L.EnvironmentDiffuseScale
	Lighting.EnvironmentSpecularScale = L.EnvironmentSpecularScale
	Lighting.ShadowSoftness = L.ShadowSoftness
	Lighting.ExposureCompensation = L.ExposureCompensation
	Lighting.GlobalShadows = true

	local atmosphere = effect("Atmosphere", "BoardAtmosphere") :: Atmosphere
	atmosphere.Density = L.AtmosphereDensity
	atmosphere.Offset = L.AtmosphereOffset
	atmosphere.Color = L.AtmosphereColor
	atmosphere.Decay = L.AtmosphereDecay
	atmosphere.Glare = L.AtmosphereGlare
	atmosphere.Haze = L.AtmosphereHaze

	local bloom = effect("BloomEffect", "BoardBloom") :: BloomEffect
	bloom.Intensity = L.BloomIntensity
	bloom.Size = L.BloomSize
	bloom.Threshold = L.BloomThreshold

	local correction = effect("ColorCorrectionEffect", "BoardColorCorrection") :: ColorCorrectionEffect
	correction.Saturation = L.Saturation
	correction.Contrast = L.Contrast
	correction.Brightness = L.CorrectionBrightness
	correction.TintColor = L.Tint

	local rays = effect("SunRaysEffect", "BoardSunRays") :: SunRaysEffect
	rays.Intensity = L.SunRaysIntensity
	rays.Spread = L.SunRaysSpread
end

-- coast: list of rings, each a list of Vector2 in world studs (x, z).
function Environment.build(map: Model, coast: { { Vector2 } })
	local old = map:FindFirstChild("Environment")
	if old then
		old:Destroy()
	end
	if builtFolder and builtFolder.Parent then
		builtFolder:Destroy()
	end

	buildLighting()
	buildSea(coast)

	local folder = Instance.new("Folder")
	folder.Name = "Environment"
	local tableFolder = Instance.new("Folder")
	tableFolder.Name = "WarTable"
	tableFolder.Parent = folder
	buildTable(tableFolder)
	local boats = Instance.new("Folder")
	boats.Name = "Boats"
	boats.Parent = folder
	buildBoats(boats, coast)
	folder.Parent = map
	builtFolder = folder
end

-- Removes the sea terrain (fills the region with Air), the Board* lighting
-- effects and the last built Environment folder.
function Environment.clear()
	local terrain = Workspace.Terrain
	local size = STYLE.VoxelSize
	local halfX, halfZ = waterHalf()
	local top = STYLE.WaterLevel + size
	local step = STYLE.ChunkColumns * size
	local x = -halfX
	while x < halfX do
		local region =
			Region3.new(Vector3.new(x, STYLE.BedBottom, -halfZ), Vector3.new(math.min(x + step, halfX), top, halfZ))
		terrain:FillRegion(region:ExpandToGrid(size), size, Enum.Material.Air)
		x += step
		task.wait()
	end
	for _, child in Lighting:GetChildren() do
		if string.sub(child.Name, 1, 5) == "Board" then
			child:Destroy()
		end
	end
	if builtFolder then
		builtFolder:Destroy()
		builtFolder = nil
	end
end

return Environment
