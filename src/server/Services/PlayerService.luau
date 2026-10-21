--!strict
-- Gives each joining player a free seat (one Team per seat, from
-- GameConfig.Seats) and turns players away once every seat is taken. The seat
-- number is mirrored to the "Seat" Player attribute.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local PlayerService = {}

local seatTeams: { Team } = {}
local seatOf: { [Player]: number } = {}

function PlayerService:GetSeat(player: Player): number?
	return seatOf[player]
end

-- Players holding a seat, in seat order.
function PlayerService:GetSeatedPlayers(): { Player }
	local seated = {}
	for seat = 1, #seatTeams do
		for player, s in seatOf do
			if s == seat then
				table.insert(seated, player)
			end
		end
	end
	return seated
end

local function freeSeat(): number?
	local taken = {}
	for _, seat in seatOf do
		taken[seat] = true
	end
	for seat = 1, #seatTeams do
		if not taken[seat] then
			return seat
		end
	end
	return nil
end

function PlayerService:Init()
	for index, config in GameConfig.Seats do
		local team = Instance.new("Team")
		team.Name = config.name
		team.TeamColor = config.color
		team.AutoAssignable = false
		team:SetAttribute("Seat", index)
		team.Parent = Teams
		seatTeams[index] = team
	end
end

function PlayerService:Start()
	local function onPlayerAdded(player: Player)
		local seat = freeSeat()
		if not seat then
			player:Kick(`This server is full ({#seatTeams} players).`)
			return
		end
		seatOf[player] = seat
		player.Team = seatTeams[seat]
		player:SetAttribute("Seat", seat)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		seatOf[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return PlayerService
