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
		SlabThickness = 2,
		TerrainColors = {
			mountain = Color3.fromHex("ab9d8a"),
			plateau = Color3.fromHex("d8b98a"),
			plains = Color3.fromHex("c6dd92"),
			valley = Color3.fromHex("a2d08a"),
			desert = Color3.fromHex("eedca2"),
			forest = Color3.fromHex("80b472"),
			lake = Color3.fromHex("b4dccf"),
		} :: { [string]: Color3 },
		DeepSeaColor = Color3.fromHex("1b5582"),
		ShallowSeaColor = Color3.fromHex("5cc0bf"),
		BorderColor = Color3.fromHex("5c5c5c"),
		BorderTransparency = 0.55,
		BorderWidth = 0.8,
		RiverColor = Color3.fromHex("3a7fc8"),
		RiverWidth = 4,
		TributaryWidth = 2.5,
		ContinentEdgeColor = Color3.fromHex("d9a521"),
		ContinentEdgeWidth = 1.6,
	},
}

return table.freeze(GameConfig)
