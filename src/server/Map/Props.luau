--!strict
-- Terrain dressing for the war-table board: small low-poly diorama clusters
-- (peaks, mesas, woods, fields, paddies, dunes, ponds and buildings) built
-- only from primitive parts. Every cluster sits on a flat territory slab with
-- its base centred on `at` (the slab's top surface) and stays inside
-- Props.Footprint[kind] * scale studs of it.
--
-- Shape notes:
-- * CornerWedgePart: apex above its local (+X, -Z) corner. Four of them around
--   a shared corner make a faceted pyramid (see `pyramid`).
-- * WedgePart: full height at local +Z, zero at -Z.
-- * A cube turned so a corner points straight up (`gem`) gives a three-faced
--   rock tip or a faceted conifer tier in one part.

local Props = {}

Props.Footprint = {
	mountain = 11,
	plateau = 10,
	forest = 8,
	plains = 10,
	valley = 9,
	desert = 9,
	lake = 10,
	pagoda = 6,
	village = 9,
	watchtower = 7,
} :: { [string]: number }

local TAU = math.pi * 2
local HALF_PI = math.pi / 2
local SQRT3 = math.sqrt(3)

-- Turns a cube's (+1, +1, +1) corner to point straight up.
local CORNER_UP = CFrame.fromAxisAngle(Vector3.new(-1, 0, 1).Unit, math.acos(1 / SQRT3))
-- Turns a cylinder's length axis (X) to point up.
local UPRIGHT = CFrame.Angles(0, 0, HALF_PI)

local M = Enum.Material

local function hex(code: string): Color3
	return Color3.fromHex(code)
end

local C = {
	slateDark = hex("45464b"),
	slate = hex("55555a"),
	rock = hex("85776a"),
	rockWarm = hex("92806a"),
	rockCool = hex("7a746b"),
	rockTip = hex("d8cbb0"),
	rockTipCool = hex("cbc2b0"),

	loess1 = hex("b8864f"),
	loess2 = hex("cc9e66"),
	loess3 = hex("dcb57f"),
	loessTop = hex("bfb274"),

	pine = hex("2f6a40"),
	pineDeep = hex("285a37"),
	pineBlue = hex("33705a"),
	leaf = hex("5a9a3e"),
	leafDeep = hex("467f36"),
	leafLight = hex("7aac4a"),
	willow = hex("9fbf55"),
	bamboo = hex("7aa84a"),
	bambooDeep = hex("5c8f3b"),
	shrub = hex("7d8a4c"),
	shrubDry = hex("9a8a58"),
	trunk = hex("5b4430"),
	trunkLight = hex("715439"),

	wheat = hex("d8b34c"),
	millet = hex("c99a4e"),
	sprout = hex("9cc35f"),
	cabbage = hex("6f9c46"),
	hay = hex("d9bb6a"),

	paddy = hex("86c65a"),
	paddyWater = hex("8ccdbf"),

	sand = hex("e0c286"),
	sandWarm = hex("d6b072"),
	sandPale = hex("e8d09c"),
	redRock = hex("a9513a"),
	redRockLight = hex("c0704c"),

	water = hex("5fb0d4"),
	rimSand = hex("d9c690"),
	rimGrass = hex("86ad55"),
	reed = hex("8f9a4c"),
	lily = hex("4f8f3f"),

	stone = hex("a39d92"),
	stoneLight = hex("c2b8a5"),
	stoneDark = hex("7b766e"),
	lacquer = hex("a8362b"),
	lacquerDark = hex("8a2c25"),
	timber = hex("7a5838"),
	plaster = hex("e6dac2"),
	plasterWarm = hex("dccaa6"),
	tile = hex("56606a"),
	tileGreen = hex("4f6259"),
	tileDark = hex("464d55"),
	earthWall = hex("b99a6e"),
	gold = hex("d2a640"),
}

-- Slight brightness jitter so repeated pieces never look identical.
local function vary(color: Color3, rng: Random, amount: number): Color3
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, s, math.clamp(v * rng:NextNumber(1 - amount, 1 + amount), 0, 1))
end

local function make(
	class: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material,
	shadow: boolean,
	parent: Instance,
	shape: Enum.PartType?
): BasePart
	local part = Instance.new(class) :: BasePart
	if shape then
		(part :: Part).Shape = shape
	end
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = shadow
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = color
	part.Size = size
	part.CFrame = cf
	part.Parent = parent
	return part
end

local function block(
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material,
	shadow: boolean,
	parent: Instance
)
	return make("Part", size, cf, color, material, shadow, parent)
end

local function ball(
	diameter: number,
	pos: Vector3,
	color: Color3,
	material: Enum.Material,
	shadow: boolean,
	parent: Instance
)
	return make(
		"Part",
		Vector3.new(diameter, diameter, diameter),
		CFrame.new(pos),
		color,
		material,
		shadow,
		parent,
		Enum.PartType.Ball
	)
end

-- Upright cylinder whose bottom face is at `base` (a CFrame on the ground, may be tilted).
local function column(
	base: CFrame,
	height: number,
	diameter: number,
	color: Color3,
	material: Enum.Material,
	shadow: boolean,
	parent: Instance
)
	return make(
		"Part",
		Vector3.new(height, diameter, diameter),
		base * CFrame.new(0, height / 2, 0) * UPRIGHT,
		color,
		material,
		shadow,
		parent,
		Enum.PartType.Cylinder
	)
end

-- Flat disc lying on the ground whose top face is at `top`.
local function disc(
	pos: Vector3,
	top: number,
	thickness: number,
	diameter: number,
	color: Color3,
	material: Enum.Material,
	parent: Instance
)
	return make(
		"Part",
		Vector3.new(thickness, diameter, diameter),
		CFrame.new(pos.X, top - thickness / 2, pos.Z) * UPRIGHT,
		color,
		material,
		false,
		parent,
		Enum.PartType.Cylinder
	)
end

-- A cube standing on one corner with its top corner at `top`; sunk into the ground it
-- shows a three-faced crag.
local function gem(
	top: Vector3,
	size: number,
	yaw: number,
	color: Color3,
	material: Enum.Material,
	shadow: boolean,
	parent: Instance
)
	local cf = CFrame.new(top - Vector3.new(0, size * SQRT3 / 2, 0)) * CFrame.Angles(0, yaw, 0) * CORNER_UP
	return block(Vector3.new(size, size, size), cf, color, material, shadow, parent)
end

-- Faceted pyramid: apex `height` above `base` (a ground CFrame), base rectangle reaching
-- `a1` to -X, `a2` to +X, `b1` to -Z and `b2` to +Z. Four corner wedges, each facet shaded.
local function pyramid(
	base: CFrame,
	a1: number,
	a2: number,
	b1: number,
	b2: number,
	height: number,
	color: Color3,
	material: Enum.Material,
	shade: number,
	shadow: boolean,
	rng: Random,
	parent: Instance
)
	local quads = {
		{ a1, b2, -a1 / 2, b2 / 2 },
		{ b2, a2, a2 / 2, b2 / 2 },
		{ a2, b1, a2 / 2, -b1 / 2 },
		{ b1, a1, -a1 / 2, -b1 / 2 },
	}
	for i, q in quads do
		make(
			"CornerWedgePart",
			Vector3.new(q[1], height, q[2]),
			base * CFrame.new(q[3], height / 2, q[4]) * CFrame.Angles(0, (i - 1) * HALF_PI, 0),
			vary(color, rng, shade),
			material,
			shadow,
			parent
		)
	end
end

-- Two wedges back to back: a ridge running along local X, `depth1` of slope towards -Z
-- and `depth2` towards +Z. Used for gable roofs and dunes.
local function ridge(
	base: CFrame,
	length: number,
	height: number,
	depth1: number,
	depth2: number,
	color1: Color3,
	color2: Color3,
	material: Enum.Material,
	shadow: boolean,
	parent: Instance
)
	make(
		"WedgePart",
		Vector3.new(length, height, depth1),
		base * CFrame.new(0, height / 2, -depth1 / 2),
		color1,
		material,
		shadow,
		parent
	)
	make(
		"WedgePart",
		Vector3.new(length, height, depth2),
		base * CFrame.new(0, height / 2, depth2 / 2) * CFrame.Angles(0, math.pi, 0),
		color2,
		material,
		shadow,
		parent
	)
end

local function ground(at: Vector3, x: number, z: number, yaw: number): CFrame
	return CFrame.new(at.X + x, at.Y, at.Z + z) * CFrame.Angles(0, yaw, 0)
end

local function polar(rng: Random, angle: number, minR: number, maxR: number): (number, number)
	local r = rng:NextNumber(minR, maxR)
	return math.cos(angle) * r, math.sin(angle) * r
end

local function pick<T>(rng: Random, list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

---------------------------------------------------------------------------
-- Trees

-- Conifer: a tall, narrow faceted pyramid standing on the ground. Returns parts used.
local function pine(at: Vector3, height: number, rng: Random, parent: Instance): number
	local color = vary(pick(rng, { C.pine, C.pineDeep, C.pineBlue }), rng, 0.08)
	local r = height * rng:NextNumber(0.17, 0.21)
	pyramid(
		CFrame.new(at - Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0),
		r * rng:NextNumber(0.9, 1.1),
		r * rng:NextNumber(0.9, 1.1),
		r * rng:NextNumber(0.9, 1.1),
		r * rng:NextNumber(0.9, 1.1),
		height,
		color,
		M.Grass,
		0.12,
		height > 3,
		rng,
		parent
	)
	return 4
end

-- Broadleaf: trunk plus a round canopy, sometimes with a second smaller lobe.
local function broadleaf(at: Vector3, height: number, rng: Random, parent: Instance, lobes: number): number
	local color = vary(pick(rng, { C.leaf, C.leafDeep, C.leafLight }), rng, 0.07)
	local crown = height * rng:NextNumber(0.62, 0.72)
	local lean = CFrame.Angles(rng:NextNumber(-0.08, 0.08), 0, rng:NextNumber(-0.08, 0.08))
	column(CFrame.new(at) * lean, height * 0.55, math.max(0.3, height * 0.08), C.trunkLight, M.Wood, false, parent)
	ball(crown, at + Vector3.new(0, height - crown / 2, 0), color, M.LeafyGrass, true, parent)
	if lobes > 1 then
		local a = rng:NextNumber(0, TAU)
		local d = crown * 0.38
		local h, s, v = color:ToHSV()
		ball(
			crown * 0.62,
			at + Vector3.new(math.cos(a) * d, height - crown * 0.62, math.sin(a) * d),
			Color3.fromHSV(h, s, v * 0.9),
			M.LeafyGrass,
			true,
			parent
		)
		return 3
	end
	return 2
end

local function shrub(at: Vector3, size: number, color: Color3, rng: Random, parent: Instance)
	ball(size, at + Vector3.new(0, size * 0.3, 0), vary(color, rng, 0.08), M.LeafyGrass, false, parent)
end

---------------------------------------------------------------------------
-- Buildings

-- Chinese gable roof: two dark wedges with deep overhang. `base` is the eave level.
local function gableRoof(base: CFrame, length: number, depth: number, height: number, rng: Random, parent: Instance)
	local color = vary(pick(rng, { C.tile, C.tileGreen, C.tileDark }), rng, 0.06)
	local h, s, v = color:ToHSV()
	ridge(base, length, height, depth / 2, depth / 2, color, Color3.fromHSV(h, s, v * 0.85), M.Slate, true, parent)
end

local function house(base: CFrame, width: number, depth: number, rng: Random, parent: Instance): number
	local wall = rng:NextNumber(1.3, 1.8) * math.min(width, 3) / 2.6
	local color = vary(pick(rng, { C.plaster, C.plasterWarm, C.plaster, C.timber }), rng, 0.04)
	block(
		Vector3.new(width, wall + 0.1, depth),
		base * CFrame.new(0, (wall + 0.1) / 2 - 0.1, 0),
		color,
		if color == C.timber then M.WoodPlanks else M.SmoothPlastic,
		true,
		parent
	)
	gableRoof(base * CFrame.new(0, wall, 0), width + 0.7, depth + 1, depth * 0.5, rng, parent)
	return 3
end

---------------------------------------------------------------------------
-- Kinds

-- One faceted peak with an optional pale cap: the cap is the same pyramid scaled down
-- about the apex and inflated a touch so it sits just outside the body's faces.
local function peak(
	frame: CFrame,
	w: number,
	tall: number,
	body: Color3,
	tip: Color3?,
	rng: Random,
	parent: Instance
): number
	local a1, a2 = w * rng:NextNumber(0.75, 1.2), w * rng:NextNumber(0.75, 1.2)
	local b1, b2 = w * rng:NextNumber(0.75, 1.2), w * rng:NextNumber(0.75, 1.2)
	pyramid(frame, a1, a2, b1, b2, tall, body, M.Slate, 0.1, true, rng, parent)
	if not tip then
		return 4
	end
	local f = rng:NextNumber(0.26, 0.34)
	local g = f * 1.08
	local capFrame = frame * CFrame.new(0, tall * (1 - f) + 0.1, 0)
	pyramid(capFrame, a1 * g, a2 * g, b1 * g, b2 * g, tall * f, tip, M.Rock, 0.06, true, rng, parent)
	return 8
end

local function mountain(at: Vector3, rng: Random, parent: Instance, k: number)
	local yaw = rng:NextNumber(0, TAU)
	local tall = rng:NextNumber(12, 17) * k
	local twin = rng:NextNumber() < 0.45
	local body = pick(rng, { C.rock, C.rockWarm, C.rockCool })
	local tip = if rng:NextNumber() < 0.5 then C.rockTip else C.rockTipCool

	-- Main peak, nudged off centre when it has a twin.
	local mx, mz = 0, 0
	if twin then
		mx, mz = polar(rng, yaw, 1.2 * k, 2 * k)
	end
	local w = tall * rng:NextNumber(0.38, 0.45)
	local frame = ground(at, mx, mz, rng:NextNumber(0, TAU)) * CFrame.new(0, -0.1, 0)
	local used = peak(frame, w, tall, body, tip, rng, parent)

	-- A lower, darker twin leaning against its flank.
	if twin then
		local px, pz = polar(rng, yaw + math.pi + rng:NextNumber(-0.5, 0.5), w * 0.95, w * 1.1)
		local h = tall * rng:NextNumber(0.55, 0.7)
		local pf = ground(at, mx + px, mz + pz, rng:NextNumber(0, TAU)) * CFrame.new(0, -0.1, 0)
		used += peak(pf, h * rng:NextNumber(0.42, 0.5), h, C.slate, nil, rng, parent)
	end

	-- Dark slate crags breaking up the foot.
	local a = yaw + rng:NextNumber(0.6, 1.4)
	for _ = 1, if twin then 1 else rng:NextInteger(2, 3) do
		local cx, cz = polar(rng, a, w * 0.8, w * 1.0)
		local s = rng:NextNumber(2.6, 3.6) * k
		gem(
			at + Vector3.new(mx + cx, s * rng:NextNumber(0.55, 0.8), mz + cz),
			s,
			rng:NextNumber(0, TAU),
			vary(C.slateDark, rng, 0.08),
			M.Slate,
			true,
			parent
		)
		used += 1
		a += rng:NextNumber(1.6, 2.4)
	end

	-- Now and then a small pine at the foot.
	if used <= 10 and rng:NextNumber() < 0.6 then
		local px, pz = polar(rng, a, w * 1.05, w * 1.25)
		pine(at + Vector3.new(mx + px, 0, mz + pz), rng:NextNumber(3, 4) * k, rng, parent)
	end
end

local function plateau(at: Vector3, rng: Random, parent: Instance, k: number)
	local yaw = rng:NextNumber(0, TAU)
	local layers = if rng:NextNumber() < 0.6 then 3 else 2
	local total = rng:NextNumber(4.5, 7.5) * k
	local colors = { C.loess1, C.loess2, C.loess3 }
	local w, d = rng:NextNumber(11, 14) * k, rng:NextNumber(8.5, 11) * k
	local y = -0.1
	local cx, cz = 0, 0
	local topW, topD, topCf = 0, 0, CFrame.new()
	for i = 1, layers do
		local h = total / layers * rng:NextNumber(0.85, 1.15) + (if i == 1 then 0.1 else 0)
		local cf = ground(at, cx, cz, yaw + rng:NextNumber(-0.2, 0.2)) * CFrame.new(0, y + h / 2, 0)
		block(Vector3.new(w, h, d), cf, vary(colors[i], rng, 0.04), M.Sandstone, true, parent)
		-- An offset spur makes the outline of the lowest terrace irregular.
		if i == 1 and rng:NextNumber() < 0.6 then
			local sw, sd = w * rng:NextNumber(0.45, 0.6), d * rng:NextNumber(0.45, 0.6)
			local side = if rng:NextNumber() < 0.5 then -1 else 1
			block(
				Vector3.new(sw, h * 0.7, sd),
				cf * CFrame.new(side * (w / 2), -h * 0.15, rng:NextNumber(-d / 4, d / 4)) * CFrame.Angles(0, 0.35, 0),
				vary(colors[1], rng, 0.05),
				M.Sandstone,
				true,
				parent
			)
		end
		topW, topD, topCf = w, d, cf * CFrame.new(0, h / 2, 0)
		y += h
		w *= rng:NextNumber(0.62, 0.74)
		d *= rng:NextNumber(0.62, 0.74)
		cx += rng:NextNumber(-0.8, 0.8) * k
		cz += rng:NextNumber(-0.8, 0.8) * k
	end
	-- Thin grassy cap on the summit and a lone shrub.
	block(
		Vector3.new(topW - 0.3, 0.12, topD - 0.3),
		topCf * CFrame.new(0, 0.05, 0),
		vary(C.loessTop, rng, 0.05),
		M.Grass,
		false,
		parent
	)
	if rng:NextNumber() < 0.6 then
		local p = (topCf * CFrame.new(rng:NextNumber(-topW, topW) * 0.25, 0, rng:NextNumber(-topD, topD) * 0.25)).Position
		shrub(p, rng:NextNumber(1, 1.6) * k, C.shrub, rng, parent)
	end
end

local function forest(at: Vector3, rng: Random, parent: Instance, k: number)
	-- Mix of conifers (4 parts), broadleaves (2-3) and low bushes (1); 7-12 parts.
	local roll = rng:NextNumber()
	local pines = if roll < 0.35 then 0 elseif roll < 0.8 then 1 else 2
	local trees: { string } = {}
	for _ = 1, pines do
		table.insert(trees, "pine")
	end
	for _ = 1, if pines == 0 then 3 elseif pines == 1 then 2 else 1 do
		table.insert(trees, "broad")
	end
	if rng:NextNumber() < 0.6 then
		table.insert(trees, "bush")
	end
	-- Shuffle so the tallest tree is not always the same kind.
	for i = #trees, 2, -1 do
		local j = rng:NextInteger(1, i)
		trees[i], trees[j] = trees[j], trees[i]
	end
	local used = 0
	local start = rng:NextNumber(0, TAU)
	local ring = #trees - 1
	for i, kind in trees do
		local x, z = 0, 0
		if i > 1 then
			x, z = polar(rng, start + (i - 1) / ring * TAU + rng:NextNumber(-0.35, 0.35), 3.4 * k, 5.2 * k)
		elseif ring > 2 then
			x, z = rng:NextNumber(-0.8, 0.8) * k, rng:NextNumber(-0.8, 0.8) * k
		end
		local spot = at + Vector3.new(x, 0, z)
		local hero = if i == 1 then 1.2 else 1
		if kind == "pine" then
			used += pine(spot, rng:NextNumber(6, 8) * k * hero, rng, parent)
		elseif kind == "broad" then
			local lobes = if used <= 9 and rng:NextNumber() < 0.35 then 2 else 1
			used += broadleaf(spot, rng:NextNumber(5, 7) * k * hero, rng, parent, lobes)
		else
			shrub(spot, rng:NextNumber(2, 2.8) * k, pick(rng, { C.leafDeep, C.leaf }), rng, parent)
			used += 1
		end
	end
end

local function plains(at: Vector3, rng: Random, parent: Instance, k: number)
	local yaw = rng:NextNumber(0, TAU)
	local cols, rows = rng:NextInteger(2, 3), 2
	local fw, fd = rng:NextNumber(4.2, 5.2) * k, rng:NextNumber(3, 3.8) * k
	local gap = 0.4 * k
	local crops = { C.wheat, C.sprout, C.millet, C.cabbage, C.wheat }
	local offset = rng:NextInteger(0, 4)
	local skip = if rng:NextNumber() < 0.6 then rng:NextInteger(1, cols * rows) else 0
	local root = ground(at, 0, 0, yaw)
	local n = 0
	local free: CFrame? = nil
	for r = 1, rows do
		local shift = (r - 1.5) * rng:NextNumber(-0.6, 0.6) * k
		for c = 1, cols do
			n += 1
			local x = (c - (cols + 1) / 2) * (fw + gap) + shift
			local z = (r - 1.5) * (fd + gap)
			if n == skip then
				free = root * CFrame.new(x, 0, z)
			else
				local color = crops[(n + offset) % #crops + 1]
				local h = rng:NextNumber(0.18, 0.32)
				block(
					Vector3.new(fw * rng:NextNumber(0.85, 1), h + 0.1, fd * rng:NextNumber(0.85, 1)),
					root * CFrame.new(x, h / 2 - 0.05, z) * CFrame.Angles(0, rng:NextNumber(-0.04, 0.04), 0),
					vary(color, rng, 0.05),
					M.SmoothPlastic,
					false,
					parent
				)
			end
		end
	end
	local spot = free or root * CFrame.new((cols / 2 + 0.3) * (fw + gap) * 0.95, 0, 0)
	local roll = rng:NextNumber()
	if roll < 0.35 then
		house(spot * CFrame.Angles(0, rng:NextNumber(-0.2, 0.2), 0), 2.6 * k, 2 * k, rng, parent)
	elseif roll < 0.75 then
		for i = 1, rng:NextInteger(1, 2) do
			local d = rng:NextNumber(1.1, 1.5) * k
			local p = spot * CFrame.new((i - 1.5) * 1.8 * k, 0, rng:NextNumber(-0.6, 0.6))
			column(p * CFrame.new(0, -0.05, 0), d * 0.7, d, vary(C.hay, rng, 0.05), M.Grass, false, parent)
			ball(d, (p * CFrame.new(0, d * 0.65, 0)).Position, vary(C.hay, rng, 0.05), M.Grass, false, parent)
		end
	end
end

local function valley(at: Vector3, rng: Random, parent: Instance, k: number)
	local yaw = rng:NextNumber(0, TAU)
	local root = ground(at, 0, 0, yaw)
	-- Stepped paddies climbing towards local -Z.
	local tiers = rng:NextInteger(2, 3)
	local w, d = rng:NextNumber(7.5, 9) * k, rng:NextNumber(4.6, 5.4) * k
	local z = 1.2 * k
	for i = 1, tiers do
		local top = 0.18 + (i - 1) * 0.45
		local wet = i % 2 == 0
		local part = block(
			Vector3.new(w, top + 0.1, d),
			root * CFrame.new(rng:NextNumber(-0.4, 0.4) * k, (top - 0.1) / 2, z),
			vary(if wet then C.paddyWater else C.paddy, rng, 0.04),
			if wet then M.Glass else M.SmoothPlastic,
			false,
			parent
		)
		if wet then
			part.Reflectance = 0.08
		end
		z -= d * 0.42
		w *= 0.78
		d *= 0.8
	end
	-- Bamboo clump on one flank.
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	local bx, bz = side * rng:NextNumber(4.2, 5) * k, rng:NextNumber(-2.5, -1) * k
	for i = 1, 3 do
		local a = i * 2.1
		local base = root
			* CFrame.new(bx + math.cos(a) * 0.5 * k, -0.05, bz + math.sin(a) * 0.5 * k)
			* CFrame.Angles(rng:NextNumber(-0.07, 0.07), 0, rng:NextNumber(-0.07, 0.07))
		column(
			base,
			rng:NextNumber(4.5, 7) * k,
			0.36 * k,
			vary(if i % 2 == 0 then C.bambooDeep else C.bamboo, rng, 0.06),
			M.SmoothPlastic,
			true,
			parent
		)
	end
	-- Weeping willow on the other flank.
	local wx, wz = -side * rng:NextNumber(4, 4.8) * k, rng:NextNumber(1, 3) * k
	local wp = (root * CFrame.new(wx, 0, wz)).Position
	local h = rng:NextNumber(4.5, 6) * k
	column(CFrame.new(wp) * CFrame.Angles(0, 0, side * 0.12), h * 0.6, 0.45 * k, C.trunk, M.Wood, false, parent)
	local crown = h * 0.72
	ball(
		crown,
		wp + Vector3.new(-side * 0.35 * k, h - crown / 2, 0),
		vary(C.willow, rng, 0.06),
		M.LeafyGrass,
		true,
		parent
	)
	ball(
		crown * 0.7,
		wp + Vector3.new(-side * 0.9 * k, h - crown * 0.85, rng:NextNumber(-0.6, 0.6)),
		vary(C.willow, rng, 0.06):Lerp(C.leafLight, 0.3),
		M.LeafyGrass,
		true,
		parent
	)
end

local function desert(at: Vector3, rng: Random, parent: Instance, k: number)
	local wind = rng:NextNumber(0, TAU)
	local sands = { C.sand, C.sandWarm, C.sandPale }
	local mounds = 2
	-- Half the time a big faceted star dune, its apex pushed downwind.
	if rng:NextNumber() < 0.5 then
		local df = ground(at, rng:NextNumber(-1, 1) * k, rng:NextNumber(-1, 1) * k, wind) * CFrame.new(0, -0.1, 0)
		pyramid(
			df,
			rng:NextNumber(3.5, 4.5) * k,
			rng:NextNumber(1.8, 2.4) * k,
			rng:NextNumber(3, 4) * k,
			rng:NextNumber(3, 4) * k,
			rng:NextNumber(2, 2.8) * k,
			pick(rng, sands),
			M.Sand,
			0.07,
			true,
			rng,
			parent
		)
		mounds = 1
	end
	-- Long rounded dunes: buried cylinders lying across the wind.
	for i = 1, mounds do
		local offset = if mounds == 1 then 5 else 3.2
		local dx, dz = polar(
			rng,
			wind + HALF_PI * (if i == 1 then 1 else -1) + rng:NextNumber(-0.3, 0.3),
			offset * k,
			(offset + 1) * k
		)
		local radius = rng:NextNumber(3, 4) * k
		local rise = rng:NextNumber(1.2, 1.9) * k
		make(
			"Part",
			Vector3.new(rng:NextNumber(6, 8.5) * k, radius * 2, radius * 2),
			ground(at, dx, dz, wind + rng:NextNumber(-0.25, 0.25)) * CFrame.new(0, rise - radius, 0),
			vary(pick(rng, sands), rng, 0.04),
			M.Sand,
			true,
			parent,
			Enum.PartType.Cylinder
		)
	end
	-- Red sandstone butte with a lighter cap band.
	local bx, bz = polar(rng, wind + math.pi + rng:NextNumber(-0.8, 0.8), 4.5 * k, 5.5 * k)
	local bh = rng:NextNumber(3, 4.6) * k
	local bw = rng:NextNumber(2.2, 3) * k
	local bf = ground(at, bx, bz, rng:NextNumber(0, TAU))
	block(
		Vector3.new(bw, bh, bw * rng:NextNumber(0.7, 0.95)),
		bf * CFrame.new(0, bh / 2 - 0.1, 0),
		vary(C.redRock, rng, 0.05),
		M.Sandstone,
		true,
		parent
	)
	block(
		Vector3.new(bw * 0.8, 0.7 * k, bw * 0.6),
		bf * CFrame.new(bw * 0.06, bh + 0.25 * k - 0.1, 0) * CFrame.Angles(0, 0.2, 0),
		vary(C.redRockLight, rng, 0.05),
		M.Sandstone,
		true,
		parent
	)
	if rng:NextNumber() < 0.6 then
		local sx, sz = polar(rng, wind - HALF_PI, 5 * k, 6.5 * k)
		shrub(at + Vector3.new(sx, 0, sz), rng:NextNumber(0.8, 1.2) * k, C.shrubDry, rng, parent)
	end
end

local function lake(at: Vector3, rng: Random, parent: Instance, k: number)
	local r1 = rng:NextNumber(3.6, 4.4) * k
	local r2 = rng:NextNumber(2.4, 3.2) * k
	local a = rng:NextNumber(0, TAU)
	local ox, oz = math.cos(a) * r1 * 0.75, math.sin(a) * r1 * 0.75
	local p1 = at + Vector3.new(-ox * 0.3, 0, -oz * 0.3)
	local p2 = at + Vector3.new(ox, 0, oz)
	local rim = if rng:NextNumber() < 0.5 then C.rimSand else C.rimGrass
	disc(p1, at.Y + 0.02, 0.3, (r1 + 0.8) * 2, vary(rim, rng, 0.04), M.Sand, parent)
	disc(p2, at.Y + 0.02, 0.3, (r2 + 0.8) * 2, vary(rim, rng, 0.04), M.Sand, parent)
	for _, w in { { p1, r1 }, { p2, r2 } } do
		local water = disc(w[1] :: Vector3, at.Y + 0.05, 0.3, (w[2] :: number) * 2, C.water, M.Glass, parent)
		water.Transparency = 0.15
		water.Reflectance = 0.1
	end
	-- Reeds on the far bank.
	local ra = a + math.pi + rng:NextNumber(-0.5, 0.5)
	local rp = p1 + Vector3.new(math.cos(ra) * (r1 + 0.2), 0, math.sin(ra) * (r1 + 0.2))
	for i = 1, rng:NextInteger(2, 3) do
		local h = rng:NextNumber(1.2, 2) * k
		block(
			Vector3.new(0.18, h, 0.18),
			CFrame.new(rp + Vector3.new((i - 2) * 0.45, h / 2, rng:NextNumber(-0.3, 0.3)))
				* CFrame.Angles(rng:NextNumber(-0.25, 0.25), 0, rng:NextNumber(-0.25, 0.25)),
			vary(C.reed, rng, 0.08),
			M.SmoothPlastic,
			false,
			parent
		)
	end
	for _ = 1, rng:NextInteger(1, 2) do
		local la = rng:NextNumber(0, TAU)
		local lr = rng:NextNumber(0.3, 0.7) * r1
		disc(
			p1 + Vector3.new(math.cos(la) * lr, 0, math.sin(la) * lr),
			at.Y + 0.1,
			0.08,
			rng:NextNumber(0.7, 1.1) * k,
			vary(C.lily, rng, 0.08),
			M.SmoothPlastic,
			parent
		)
	end
end

local function pagoda(at: Vector3, rng: Random, parent: Instance, k: number)
	local tiers = rng:NextInteger(3, 5)
	local root = ground(at, 0, 0, rng:NextNumber(0, TAU))
	local baseW = 4.4 * k
	local plinth = 0.7 * k
	block(
		Vector3.new(baseW, plinth + 0.1, baseW),
		root * CFrame.new(0, (plinth + 0.1) / 2 - 0.1, 0),
		vary(C.stoneLight, rng, 0.04),
		M.Slate,
		true,
		parent
	)
	local tall = rng:NextNumber(10, 13) * k
	local roofTop = tall * 0.86
	local storey = (roofTop - plinth) / tiers
	local body = vary(if rng:NextNumber() < 0.7 then C.lacquer else C.timber, rng, 0.05)
	local roof = vary(if rng:NextNumber() < 0.5 then C.tileGreen else C.tile, rng, 0.05)
	-- Tapering core in two parts.
	local lowerH = storey * math.ceil(tiers / 2)
	block(
		Vector3.new(2.6 * k, lowerH, 2.6 * k),
		root * CFrame.new(0, plinth + lowerH / 2, 0),
		body,
		M.WoodPlanks,
		true,
		parent
	)
	block(
		Vector3.new(1.9 * k, roofTop - plinth - lowerH, 1.9 * k),
		root * CFrame.new(0, (roofTop + plinth + lowerH) / 2, 0),
		body,
		M.WoodPlanks,
		true,
		parent
	)
	-- Eaves: one thin, wide tile slab per storey, shrinking upwards.
	for i = 1, tiers - 1 do
		local y = plinth + storey * i
		local span = (4.6 - (i - 1) / math.max(1, tiers - 2) * 1.4) * k
		block(
			Vector3.new(span, 0.32 * k, span),
			root * CFrame.new(0, y, 0),
			vary(roof, rng, 0.04),
			M.Slate,
			true,
			parent
		)
	end
	-- Pyramid crown roof and golden spire.
	local crownW = 1.8 * k
	local crownH = roofTop - (plinth + storey * (tiers - 1)) + 0.6 * k
	pyramid(
		root * CFrame.new(0, plinth + storey * (tiers - 1) - 0.1 * k, 0),
		crownW,
		crownW,
		crownW,
		crownW,
		crownH,
		roof,
		M.Slate,
		0.05,
		true,
		rng,
		parent
	)
	column(root * CFrame.new(0, roofTop + 0.3 * k, 0), tall - roofTop, 0.25 * k, C.gold, M.SmoothPlastic, false, parent)
end

local function village(at: Vector3, rng: Random, parent: Instance, k: number)
	local yaw = rng:NextNumber(0, TAU)
	local count = rng:NextInteger(3, 4)
	local start = rng:NextNumber(0, TAU)
	for i = 1, count do
		local x, z = 0, 0
		if i > 1 then
			x, z = polar(rng, start + i / count * TAU + rng:NextNumber(-0.3, 0.3), 3.6 * k, 4.6 * k)
		end
		local turn = if rng:NextNumber() < 0.5 then 0 else HALF_PI
		local width = (if i == 1 then rng:NextNumber(3.4, 4) else rng:NextNumber(2.4, 3.2)) * k
		house(
			ground(at, x, z, yaw + turn + rng:NextNumber(-0.1, 0.1)),
			width,
			width * rng:NextNumber(0.62, 0.75),
			rng,
			parent
		)
	end
	-- Rammed-earth wall segment along one edge.
	local wa = start + rng:NextNumber(0, TAU)
	local wx, wz = math.cos(wa) * 6.6 * k, math.sin(wa) * 6.6 * k
	local len = rng:NextNumber(5, 7) * k
	block(
		Vector3.new(len, 1.3 * k, 0.6 * k),
		CFrame.lookAt(Vector3.new(at.X + wx, at.Y + 0.65 * k - 0.1, at.Z + wz), at + Vector3.new(0, 0.65 * k - 0.1, 0)),
		vary(C.earthWall, rng, 0.05),
		M.Sandstone,
		true,
		parent
	)
end

local function watchtower(at: Vector3, rng: Random, parent: Instance, k: number)
	local yaw = rng:NextNumber(0, TAU)
	local withWall = rng:NextNumber() < 0.6
	local tx = if withWall then rng:NextNumber(-1.5, 1.5) * k else 0
	local root = ground(at, 0, 0, yaw) * CFrame.new(tx, 0, 0)
	local h = rng:NextNumber(6.5, 8) * k
	local w = 3 * k
	block(
		Vector3.new(w, h + 0.1, w),
		root * CFrame.new(0, (h + 0.1) / 2 - 0.1, 0),
		vary(C.stone, rng, 0.04),
		M.Slate,
		true,
		parent
	)
	-- Overhanging stone platform with corner merlons.
	block(
		Vector3.new(w + 0.8 * k, 0.5 * k, w + 0.8 * k),
		root * CFrame.new(0, h + 0.25 * k, 0),
		vary(C.stoneLight, rng, 0.04),
		M.Slate,
		true,
		parent
	)
	local m = (w + 0.8 * k) / 2 - 0.3 * k
	for i = 0, 1 do
		block(
			Vector3.new(0.6 * k, 0.6 * k, 0.6 * k),
			root * CFrame.new(if i == 0 then m else -m, h + 0.8 * k, if i == 0 then m else -m),
			vary(C.stoneLight, rng, 0.04),
			M.Slate,
			false,
			parent
		)
	end
	-- Lookout hut with a hipped tile roof.
	local hut = 1.6 * k
	block(
		Vector3.new(hut * 1.3, hut, hut * 1.3),
		root * CFrame.new(0, h + 0.5 * k + hut / 2, 0),
		vary(C.lacquerDark, rng, 0.05),
		M.WoodPlanks,
		true,
		parent
	)
	local r = (hut * 1.3) / 2 + 0.6 * k
	pyramid(
		root * CFrame.new(0, h + 0.5 * k + hut, 0),
		r,
		r,
		r,
		r,
		1.4 * k,
		vary(C.tile, rng, 0.04),
		M.Slate,
		0.06,
		true,
		rng,
		parent
	)
	if withWall then
		-- Great Wall stub running off the tower with crenellations.
		local len = rng:NextNumber(5.5, 7) * k
		local wh = 2 * k
		local wall = root * CFrame.new(-w / 2 - len / 2 + 0.2, 0, 0)
		block(
			Vector3.new(len, wh + 0.1, 1.4 * k),
			wall * CFrame.new(0, (wh + 0.1) / 2 - 0.1, 0),
			vary(C.stone, rng, 0.05),
			M.Slate,
			true,
			parent
		)
		local merlons = math.max(2, math.floor(len / (1.6 * k)))
		for i = 1, merlons do
			local x = -len / 2 + (i - 0.5) * len / merlons
			block(
				Vector3.new(0.6 * k, 0.5 * k, 0.35 * k),
				wall * CFrame.new(x, wh + 0.25 * k, 0.55 * k),
				vary(C.stoneLight, rng, 0.04),
				M.Slate,
				false,
				parent
			)
		end
	end
end

local BUILDERS: { [string]: (Vector3, Random, Instance, number) -> () } = {
	mountain = mountain,
	plateau = plateau,
	forest = forest,
	plains = plains,
	valley = valley,
	desert = desert,
	lake = lake,
	pagoda = pagoda,
	village = village,
	watchtower = watchtower,
}

-- Places ONE cluster of dressing of `kind` with its base centred at `at` (at.Y = ground
-- top surface). `scale` is 0.6..1.4 (bigger on bigger territories). Unknown kinds do nothing.
function Props.dress(kind: string, at: Vector3, rng: Random, parent: Instance, scale: number)
	local build = BUILDERS[kind]
	if build then
		build(at, rng, parent, math.clamp(scale, 0.6, 1.4))
	end
end

return Props
