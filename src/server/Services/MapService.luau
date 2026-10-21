--!strict
-- Makes sure the board exists when the server starts. A place saved with a
-- prebuilt Workspace.Map keeps it; otherwise it is built from MapData.

local MapBuilder = require(script.Parent.Parent.MapBuilder)

local MapService = {}

function MapService:Start()
	if not workspace:FindFirstChild("Map") then
		MapBuilder.build(workspace)
	end
end

return MapService
