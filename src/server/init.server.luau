--!strict
-- Server entry point. Every ModuleScript in Services is a service with an
-- optional Init (set up state, no yielding) and Start (connect events, loops).
-- All Init calls finish before any Start runs, so services can safely require
-- each other in Start.

local Services = script:WaitForChild("Services")

type Service = {
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
}

local loaded: { [string]: Service } = {}

for _, module in Services:GetChildren() do
	if module:IsA("ModuleScript") then
		loaded[module.Name] = require(module) :: any
	end
end

for _, service in loaded do
	if service.Init then
		service:Init()
	end
end

for name, service in loaded do
	if service.Start then
		task.spawn(function()
			debug.setmemorycategory(name)
			service:Start()
		end)
	end
end
