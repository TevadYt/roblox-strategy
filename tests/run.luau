--!strict
-- Runs every *.spec.luau in this folder with Lune: `lune run tests/run`.
-- Game modules are loaded with a stand-in `script` that mirrors the Rojo
-- tree on disk, so `require(script.Parent.X)` works as it does in Roblox.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

type Node = { [string]: any }

local cache: { [string]: any } = {}

-- Builds the stand-in instance tree up front: lune's fs calls yield, which a
-- metamethod cannot.
local function makeNode(path: string, name: string, parent: Node?): Node
	local node: Node = { Name = name, Parent = parent, __path = path }
	if fs.isDir(path) then
		for _, entry in fs.readDir(path) do
			local childName = string.gsub(string.gsub(entry, "%.spec%.luau$", ".spec"), "%.luau$", "")
			node[childName] = makeNode(`{path}/{entry}`, childName, node)
		end
	end
	return node
end

local root = makeNode(".", "root", nil)
root.src = makeNode("./src", "src", root)
root.tests = makeNode("./tests", "tests", root)

local function load(node: Node, extra: { [string]: any }?): any
	local path = node.__path
	if cache[path] ~= nil then
		return cache[path]
	end
	local environment: { [string]: any } = { script = node }
	environment.require = function(target: any)
		if type(target) == "table" and target.__path then
			return load(target)
		end
		return require(target)
	end
	for key, value in extra or {} do
		environment[key] = value
	end
	local chunk = luau.load(fs.readFile(path), { debugName = path, environment = environment })
	local result = chunk()
	cache[path] = result
	return result
end

local failures, passed = 0, 0

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failures += 1
		print(`FAIL {name}\n  {err}`)
	end
end

local function eq(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(`{label or "value"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

for _, file in fs.readDir("tests") do
	if string.match(file, "%.spec%.luau$") then
		print(`# {file}`)
		load(root.tests[string.gsub(file, "%.luau$", "")], { test = test, eq = eq })
	end
end

print(`{passed} passed, {failures} failed`)
process.exit(if failures == 0 then 0 else 1)
