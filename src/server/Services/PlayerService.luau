--!strict
-- Assigns each joining player to the team with the fewest players.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local PlayerService = {}

local function smallestTeam(): Team?
	local best: Team? = nil
	for _, team in Teams:GetTeams() do
		if not best or #team:GetPlayers() < #best:GetPlayers() then
			best = team
		end
	end
	return best
end

function PlayerService:Init()
	for _, config in GameConfig.Teams do
		local team = Instance.new("Team")
		team.Name = config.name
		team.TeamColor = config.color
		team.AutoAssignable = false
		team.Parent = Teams
	end
end

function PlayerService:Start()
	local function onPlayerAdded(player: Player)
		player.Team = smallestTeam()
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return PlayerService
