--[[
	Runs my-version's Tests.luau outside Roblox Studio, using Lune (https://github.com/lune-org/lune, tested
	with 0.9.4) for Vector3 / CFrame. The physics core is pure Luau, so results match Studio.
	    lune run tools/run_luau_tests.luau my-version/src/ReplicatedStorage/Robikes [calibrate]
	Exit code 0 = all tests pass.
]]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local process = require("@lune/process")

local dir = process.args[1] or "my-version/src/ReplicatedStorage/Robikes"
local cache, folder = {}, {}
local function req(inst)
	local name = inst.Name
	if cache[name] ~= nil then
		return cache[name]
	end
	local env = setmetatable({
		script = { Name = name, Parent = folder },
		require = req,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
	}, { __index = _G })
	cache[name] = luau.load(fs.readFile(dir .. "/" .. name .. ".luau"), { debugName = name, environment = env })()
	return cache[name]
end
setmetatable(folder, { __index = function(_, k)
	return { Name = k, Parent = folder }
end })

local Tests = req({ Name = "Tests" })
local report, ok = Tests.run()
print(report)
if process.args[2] == "calibrate" then
	print(Tests.calibrate())
end
process.exit(ok and 0 or 1)
