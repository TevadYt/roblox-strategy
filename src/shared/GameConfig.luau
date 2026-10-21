--!strict
-- Tunable game values shared by server and client. The server is the only
-- side that acts on them; the client reads them for display.

export type TeamConfig = {
	name: string,
	color: BrickColor,
}

local GameConfig = {
	Teams = {
		{ name = "Red", color = BrickColor.new("Bright red") },
		{ name = "Blue", color = BrickColor.new("Bright blue") },
	} :: { TeamConfig },

	-- Resource names, in display order.
	Resources = { "Gold", "Wood", "Stone" } :: { string },

	StartingResources = {
		Gold = 100,
		Wood = 50,
		Stone = 0,
	} :: { [string]: number },

	-- Passive income granted every IncomeInterval seconds.
	PassiveIncome = {
		Gold = 5,
		Wood = 2,
		Stone = 0,
	} :: { [string]: number },

	IncomeInterval = 5,

	-- How the board from MapData is laid out in the world.
	Map = {
		StudsPerPixel = 0.5,
		-- Height of the lowest ground; Elevation now sets each slab's top.
		SlabThickness = 2,
		Seed = 7,
		WaterLevel = 0,
		-- Slabs reach down under the water so the coast shows as a low cliff.
		SlabBottom = -4,
		-- Top of each territory's slab, by its main terrain.
		Elevation = {
			mountain = 9,
			plateau = 6.5,
			forest = 3.5,
			desert = 3.5,
			plains = 3,
			valley = 2.5,
			lake = 2.2,
		} :: { [string]: number },
		-- Resources painted as their own patch of terrain.
		ResourceTerrain = { forest = "forest", pond = "lake" } :: { [string]: string },
		-- Patch radius as a share of the territory's radius.
		ZoneRadius = { terrain = 0.45, forest = 0.36, pond = 0.24 } :: { [string]: number },
		-- Lighten or darken each territory, and each terrain patch, a little.
		TerritoryShade = 0.05,
		ColorJitter = 0.04,
		-- Discs that make up one terrain patch.
		PatchDiscs = 7,
		-- Open ground (studs) around each center for armies and a banner.
		CenterClear = 18,
		EdgeMargin = 1.5,
		-- How much of a cluster's footprint must clear the border.
		EdgeFit = 0.7,
		-- One scatter attempt per this many square studs.
		ScatterArea = 22,
		-- How far apart clusters sit, as a share of their combined footprints.
		PropSpacing = 0.85,
		-- Chance a scatter attempt keeps its cluster, by terrain.
		PropDensity = {
			mountain = 1,
			forest = 1,
			plateau = 0.7,
			valley = 0.65,
			plains = 0.5,
			desert = 0.5,
			lake = 0.5,
		} :: { [string]: number },
		PropScale = { small = 0.85, medium = 1, large = 1.12 } :: { [string]: number },
		-- One landmark in some territories, by main terrain.
		LandmarkChance = 0.3,
		Landmarks = {
			plains = "village",
			valley = "pagoda",
			forest = "pagoda",
			mountain = "watchtower",
			plateau = "watchtower",
			desert = "watchtower",
		} :: { [string]: string },
		-- How far either side of a line to look for the ground under it.
		SideProbe = 3,
		TerrainColors = {
			mountain = Color3.fromHex("8a7d6c"),
			plateau = Color3.fromHex("c79a5e"),
			plains = Color3.fromHex("a9c464"),
			valley = Color3.fromHex("7db35a"),
			desert = Color3.fromHex("e2c483"),
			forest = Color3.fromHex("4f8a45"),
			lake = Color3.fromHex("86c7c0"),
		} :: { [string]: Color3 },
		DeepSeaColor = Color3.fromHex("1b5582"),
		ShallowSeaColor = Color3.fromHex("5cc0bf"),
		BorderColor = Color3.fromHex("5c5c5c"),
		BorderTransparency = 0.55,
		BorderWidth = 0.8,
		RiverColor = Color3.fromHex("3a8fd8"),
		RiverBankColor = Color3.fromHex("2d5f7a"),
		RiverBankExtra = 1.6,
		RiverWidth = 5,
		TributaryWidth = 3,
		ContinentEdgeColor = Color3.fromHex("e0ad2a"),
		ContinentEdgeMaterial = Enum.Material.Metal,
		ContinentEdgeWidth = 2.4,
	},

	-- Board camera on the client (MapCamera): 3D war table view and 2D map.
	Camera = {
		-- Land the focus point is kept over (board is centred on the origin).
		LandHalfX = 710,
		LandHalfZ = 460,
		-- Whole board including sea and table frame; 2D fits this on screen.
		BoardHalfX = 810,
		BoardHalfZ = 560,
		-- Height of the orbit point (ground tops are Y 2..11).
		FocusY = 6,

		-- 3D war table view.
		Fov3D = 70,
		MinDistance = 90,
		MaxDistance = 1100,
		StartDistance = 950,
		PitchNear = 38, -- pitch at MinDistance
		PitchFar = 70, -- pitch at MaxDistance
		MaxYaw = 35, -- either side of north up
		YawKeySpeed = 70,

		-- 2D strategic map.
		Fov2D = 16,
		Min2DHalfHeight = 70, -- closest 2D zoom, as visible half height
		Fit2DMargin = 1.04, -- padding when fitting the board; also the 2D zoom-out limit
		Fit2DOnEnter = true, -- entering 2D recentres and shows the whole board
		LabelScale2D = 1.35,
		TransitionTime = 0.6,

		-- Input.
		PanKeySpeed = 1.3, -- in visible half heights per second
		ZoomStep = 0.88, -- distance multiplier per wheel notch towards the board
		MinTiltFactor = 0.3, -- floor for the drag foreshortening correction

		-- Damping rates; higher is snappier. Frame-rate independent.
		FocusDamping = 12,
		ZoomDamping = 10,
		YawDamping = 10,

		-- Hide the thumbstick and jump button; the camera owns touch.
		HideTouchControls = true,
	},
}

return table.freeze(GameConfig)
