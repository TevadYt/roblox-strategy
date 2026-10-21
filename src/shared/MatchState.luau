--!strict
-- Where the match lives for both sides: ReplicatedStorage.MatchState, a
-- folder the server creates. Only MatchService on the server writes it.
--
-- Attributes on the folder:
--   Phase           "Waiting", "Starting", "Reinforce", "Attack", "Occupy",
--                   "Fortify" or "Over"
--   CurrentPlayer   UserId whose turn it is, 0 when nobody's
--   Turn            turn number, counting every player's turn
--   PhaseEndsAt     workspace:GetServerTimeNow() when the phase times out
--   Reinforcements  armies the current player still has to place
--   OccupyFrom, OccupyTo, OccupyMax
--                   during Occupy: the attack and how many more may move in
--   Winner          UserId of the winner once Phase is "Over", 0 for none
-- Player attribute "Eliminated" is true for players out of the match.
--
-- Remotes inside the folder:
--   MatchRequest (client -> server): action, ...args. Actions:
--     "Place", territory, count
--     "Attack", from, to, dice
--     "Occupy", extra          (0 or more armies beyond the dice already moved)
--     "EndAttack"
--     "Fortify", from, to, count
--     "EndTurn"
--   MatchEvent (server -> clients): kind, payload. Kinds are the rule events
--     (TurnStarted, PhaseChanged, Placed, Battle, Conquered, Moved,
--     Eliminated, GameOver; see server Rules/Match), plus "Rejected" sent only
--     to the player whose request failed, with { action, reason }.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NAME = "MatchState"

local MatchState = {}

MatchState.Actions = table.freeze({
	Place = true,
	Attack = true,
	Occupy = true,
	EndAttack = true,
	Fortify = true,
	EndTurn = true,
})

-- The folder holding the match state. The server creates it with its
-- remotes; clients wait for it.
function MatchState.Folder(): Folder
	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = NAME
			for _, remote in { "MatchRequest", "MatchEvent" } do
				local event = Instance.new("RemoteEvent")
				event.Name = remote
				event.Parent = folder
			end
			folder.Parent = ReplicatedStorage
		end
		return folder :: Folder
	end
	return ReplicatedStorage:WaitForChild(NAME) :: Folder
end

function MatchState.Request(): RemoteEvent
	return MatchState.Folder():WaitForChild("MatchRequest") :: RemoteEvent
end

function MatchState.Event(): RemoteEvent
	return MatchState.Folder():WaitForChild("MatchEvent") :: RemoteEvent
end

return MatchState
