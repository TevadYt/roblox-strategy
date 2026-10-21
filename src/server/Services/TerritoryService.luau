--!strict
-- Owns who holds each territory and how many armies are on it. Values live
-- only here and are mirrored to ReplicatedStorage.TerritoryState (see
-- Shared.Territories) so clients can display them.
--
-- Other services change the board only through this API. Changed fires with
-- the territory id after any owner or troop change.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Territories = require(ReplicatedStorage.Shared.Territories)

local config = GameConfig.Territories

local TerritoryService = {}

local owners: { [number]: Player? } = {}
local troops: { [number]: number } = {}
local state: Folder
local changed = Instance.new("BindableEvent")

TerritoryService.Changed = changed.Event

local function publish(id: number)
	local owner = owners[id]
	state:SetAttribute(Territories.OwnerAttribute(id), if owner then owner.UserId else 0)
	state:SetAttribute(Territories.TroopsAttribute(id), troops[id] or 0)
	changed:Fire(id)
end

local function check(id: number)
	assert(Territories.Get(id), `unknown territory {id}`)
end

function TerritoryService:GetOwner(id: number): Player?
	return owners[id]
end

function TerritoryService:SetOwner(id: number, player: Player?)
	check(id)
	owners[id] = player
	publish(id)
end

function TerritoryService:GetTroops(id: number): number
	return troops[id] or 0
end

function TerritoryService:SetTroops(id: number, amount: number)
	check(id)
	troops[id] = math.max(0, math.floor(amount))
	publish(id)
end

function TerritoryService:AddTroops(id: number, amount: number)
	TerritoryService:SetTroops(id, (troops[id] or 0) + amount)
end

function TerritoryService:GetTerritoriesOf(player: Player): { number }
	local held = {}
	for _, id in Territories.Ids() do
		if owners[id] == player then
			table.insert(held, id)
		end
	end
	return held
end

-- Deals every territory out evenly at random with one army on each, then
-- spreads the rest of each player's starting armies over their own
-- territories. Anything already on the board is replaced.
function TerritoryService:Deal(players: { Player })
	local rng = Random.new()
	local ids = Territories.Ids()
	for i = #ids, 2, -1 do
		local j = rng:NextInteger(1, i)
		ids[i], ids[j] = ids[j], ids[i]
	end

	local order = table.clone(players)
	for i = #order, 2, -1 do
		local j = rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end

	local held: { [Player]: { number } } = {}
	for _, player in order do
		held[player] = {}
	end
	for index, id in ids do
		local player = if #order > 0 then order[(index - 1) % #order + 1] else nil
		owners[id] = player
		troops[id] = 1
		if player then
			table.insert(held[player], id)
		end
	end

	for _, list in held do
		for _ = 1, if #list > 0 then config.StartingArmiesPerPlayer - #list else 0 do
			local id = list[rng:NextInteger(1, #list)]
			troops[id] += 1
		end
	end

	for _, id in Territories.Ids() do
		publish(id)
	end
end

function TerritoryService:Init()
	state = Territories.State()
	for _, id in Territories.Ids() do
		owners[id] = nil
		troops[id] = 0
		publish(id)
	end
end

function TerritoryService:Start()
	-- A player who leaves keeps their armies on the board, now neutral.
	Players.PlayerRemoving:Connect(function(player)
		for id, owner in owners do
			if owner == player then
				TerritoryService:SetOwner(id, nil)
			end
		end
	end)

	if not config.AutoDeal then
		return
	end
	if #Players:GetPlayers() == 0 then
		Players.PlayerAdded:Wait()
	end
	task.wait(config.AutoDealDelay)
	local PlayerService = require(script.Parent.PlayerService) :: any
	TerritoryService:Deal(PlayerService:GetSeatedPlayers())
end

return TerritoryService
