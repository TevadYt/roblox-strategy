--!strict
-- Owns every player's resources. Values live only on the server and are
-- mirrored to Player attributes ("Resource_Gold", ...) so clients can display
-- them without being able to change them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local ResourceService = {}

local balances: { [Player]: { [string]: number } } = {}

local function publish(player: Player, resource: string, amount: number)
	player:SetAttribute("Resource_" .. resource, amount)
end

function ResourceService:Get(player: Player, resource: string): number
	local balance = balances[player]
	return if balance then balance[resource] or 0 else 0
end

function ResourceService:Add(player: Player, resource: string, amount: number)
	local balance = balances[player]
	if not balance or amount == 0 then
		return
	end
	balance[resource] = (balance[resource] or 0) + amount
	publish(player, resource, balance[resource])
end

-- Spends all of `cost` or nothing. Returns whether the player could afford it.
function ResourceService:TrySpend(player: Player, cost: { [string]: number }): boolean
	local balance = balances[player]
	if not balance then
		return false
	end
	for resource, amount in cost do
		if (balance[resource] or 0) < amount then
			return false
		end
	end
	for resource, amount in cost do
		balance[resource] -= amount
		publish(player, resource, balance[resource])
	end
	return true
end

function ResourceService:Start()
	local function onPlayerAdded(player: Player)
		local balance = {}
		for _, resource in GameConfig.Resources do
			balance[resource] = GameConfig.StartingResources[resource] or 0
			publish(player, resource, balance[resource])
		end
		balances[player] = balance
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		balances[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	while true do
		task.wait(GameConfig.IncomeInterval)
		for player in balances do
			for resource, amount in GameConfig.PassiveIncome do
				ResourceService:Add(player, resource, amount)
			end
		end
	end
end

return ResourceService
