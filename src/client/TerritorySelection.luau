--!strict
-- Which territory the local player has selected. Clicking or tapping a
-- territory on the board selects it; clicking it again, clicking off the
-- board or pressing Escape clears it. Selection is display only: anything the
-- player wants to do with it goes to the server as a request.
--
-- Other client code reads Get() and listens to Changed (new id or nil).

local UserInputService = game:GetService("UserInputService")

local TerritorySelection = {}

local selected: number? = nil
local changed = Instance.new("BindableEvent")

TerritorySelection.Changed = changed.Event

function TerritorySelection.Get(): number?
	return selected
end

function TerritorySelection.Set(id: number?)
	if id == selected then
		return
	end
	selected = id
	changed:Fire(id)
end

-- The territory id of the board model `part` belongs to, if any.
local function territoryOf(part: Instance): number?
	local node: Instance? = part
	while node and node ~= workspace do
		local id = node:GetAttribute("Id")
		if node:IsA("Model") and typeof(id) == "number" and node.Parent and node.Parent.Name == "Territories" then
			return id
		end
		node = node.Parent
	end
	return nil
end

local function pick(screen: Vector2)
	local map = workspace:FindFirstChild("Map")
	local board = map and map:FindFirstChild("Territories")
	if not board then
		return
	end
	-- Only the territory slabs count, so borders and rivers drawn on top
	-- don't block a click.
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { board }
	params.FilterType = Enum.RaycastFilterType.Include
	local ray = workspace.CurrentCamera:ScreenPointToRay(screen.X, screen.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * 10000, params)
	local id = if result then territoryOf(result.Instance) else nil
	TerritorySelection.Set(if id == selected then nil else id)
end

function TerritorySelection.start()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			pick(Vector2.new(input.Position.X, input.Position.Y))
		elseif input.KeyCode == Enum.KeyCode.Escape then
			TerritorySelection.Set(nil)
		end
	end)
	UserInputService.TouchTap:Connect(function(positions, processed)
		if not processed and positions[1] then
			pick(positions[1])
		end
	end)
end

return TerritorySelection
