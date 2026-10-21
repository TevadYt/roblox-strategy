--!strict
-- Makes sure the board exists when the server starts. A place saved with a
-- prebuilt Workspace.Map keeps it, unless it was built at another world scale;
-- otherwise it is built from MapData.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local MapBuilder = require(script.Parent.Parent.MapBuilder)

local MapService = {}

function MapService:Init()
	-- Players only work the board camera. An avatar would stand on the board
	-- several times taller than its mountains, so none is spawned.
	Players.CharacterAutoLoads = false
end

function MapService:Start()
	local map = workspace:FindFirstChild("Map")
	if not map or map:GetAttribute("WorldScale") ~= GameConfig.Map.WorldScale then
		MapBuilder.build(workspace)
	end
end

return MapService
