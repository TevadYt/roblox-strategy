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
}

return table.freeze(GameConfig)
