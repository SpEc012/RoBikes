--!nonstrict
--[[
	TrackBuilder — builds the original Robikes test track out of Terrain (run once in edit mode):
	    require(game.ReplicatedStorage.Robikes.TrackBuilder).build()
	Layout is in metres (converted with Config.STUDS_PER_METER). An oval with two straights and two turns:
	  straight A (x = -20 m, heading +Z): start pad, tabletop, whoops
	  turn 1 (z = +50 m): banked berm
	  straight B (x = +20 m, heading -Z): double jump (case-able face), sand section, step-up
	  turn 2 (z = -50 m): flat turn with a mud patch
	  plus an asphalt pad at x = +55 m for supermoto grip tests.
	Work is chunked with task.wait() so Studio stays responsive.
]]

local Config = require(script.Parent.RobikesConfig)

local TrackBuilder = {}

local S = Config.STUDS_PER_METER
local M = Enum.Material
local TRACK_W = 9 -- metres
local THICK = 6 -- metres of fill under sloped faces

local function v(x, y, z)
	return Vector3.new(x, y, z) * S
end

-- flat slab with its top at yTop (metres)
local function slab(t, cx, cz, w, l, yTop, mat, yaw)
	local cf = CFrame.new(v(cx, yTop - THICK / 2, cz)) * CFrame.Angles(0, yaw or 0, 0)
	t:FillBlock(cf, v(w, THICK, l), mat)
end

-- straight ramp whose TOP surface runs from (along=a0, height=h0) to (a1, h1) on a line through (x, z) along yaw
local function ramp(t, x, z, yaw, a0, a1, h0, h1, width, mat)
	local run = a1 - a0
	local rise = h1 - h0
	local len = math.sqrt(run * run + rise * rise)
	local theta = math.atan2(rise, run)
	local base = CFrame.new(v(x, 0, z)) * CFrame.Angles(0, yaw, 0)
	-- local +Z of the block points along the ramp (forward = -Z in Roblox, so walk "along" toward -Z)
	local midAlong = (a0 + a1) / 2
	local midH = (h0 + h1) / 2
	local frame = base * CFrame.new(0, midH * S, -midAlong * S) * CFrame.Angles(theta, 0, 0)
	local center = frame * CFrame.new(0, -THICK / 2 * S, 0)
	t:FillBlock(center, v(width, THICK, len), mat)
end

-- banked arc (berm): segments tilted toward the turn centre
local function berm(t, cx, cz, radius, a0, a1, bankDeg, width, mat)
	local steps = math.max(6, math.floor(math.abs(a1 - a0) / math.rad(8)))
	local segLen = math.abs(a1 - a0) * radius / steps * 1.25
	for i = 0, steps - 1 do
		local a = a0 + (a1 - a0) * (i + 0.5) / steps
		local px, pz = cx + math.cos(a) * radius, cz + math.sin(a) * radius
		-- tangent heading and outward direction
		local outward = Vector3.new(math.cos(a), 0, math.sin(a))
		local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
		local rise = math.tan(math.rad(bankDeg)) * width * 0.5
		local cf = CFrame.fromMatrix(v(px, rise * 0.5, pz), tangent, Vector3.yAxis)
		-- roll so the outer edge is higher than the inner edge
		local up = (Vector3.yAxis * math.cos(math.rad(bankDeg)) - outward * math.sin(math.rad(bankDeg))).Unit
		local right = up:Cross(-tangent)
		cf = CFrame.fromMatrix(v(px, rise * 0.5, pz), right, up)
		t:FillBlock(cf * CFrame.new(0, -THICK / 2 * S, 0), v(width, THICK, segLen), mat)
	end
end

local function hump(t, x, z, height, halfLen, mat)
	local r = (halfLen * halfLen + height * height) / (2 * height)
	for _, dx in ipairs({ -3, 0, 3 }) do
		t:FillBall(v(x + dx, height - r, z), r * S, mat)
	end
end

local function marker(parent, name, pos, size, color, material, transparency)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = pos
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

function TrackBuilder.build()
	local t = workspace.Terrain
	-- park the template baseplate/spawn so they don't fight the terrain (kept in ServerStorage, not deleted)
	local storage = game:GetService("ServerStorage")
	for _, name in ipairs({ "Baseplate", "SpawnLocation" }) do
		local o = workspace:FindFirstChild(name)
		if o then
			o.Parent = storage
		end
	end
	local old = workspace:FindFirstChild("RobikesTrack")
	if old then
		old:Destroy()
	end
	t:Clear()
	task.wait()

	-- base ground: grass everywhere, in 4 chunks
	for ix = -1, 0 do
		for iz = -1, 0 do
			slab(t, ix * 130 + 65, iz * 130 + 65, 130, 130, 0, M.Grass)
			task.wait()
		end
	end

	-- dirt oval
	slab(t, -20, 0, TRACK_W, 104, 0.05, M.Ground) -- straight A
	slab(t, 20, 0, TRACK_W, 104, 0.05, M.Ground) -- straight B
	for i = 0, 18 do
		local a = math.rad(i * 10)
		slab(t, math.cos(a) * 20, 50 + math.sin(a) * 20, TRACK_W + 1, 7.5, 0.05, M.Ground, -a)
		slab(t, math.cos(a + math.pi) * 20, -50 + math.sin(a + math.pi) * 20, TRACK_W + 1, 7.5, 0.05, M.Ground, -(a + math.pi))
	end
	task.wait()

	-- straight A (heading +Z => yaw = pi so "along" grows toward +Z)
	local A, yawA = -20, math.pi
	slab(t, A, -44, TRACK_W, 8, 0.10, M.Concrete) -- start pad
	ramp(t, A, 0, yawA, -15, -9, 0, 1.8, TRACK_W, M.Ground) -- tabletop take-off
	slab(t, A, -3, TRACK_W, 12, 1.8, M.Ground) -- table top
	ramp(t, A, 0, yawA, 3, 13, 1.8, 0, TRACK_W, M.Ground) -- landing
	task.wait()
	for k = 0, 6 do
		hump(t, A, 20 + k * 2.8, 0.5, 1.3, M.Ground) -- whoops
	end
	task.wait()

	-- turn 1: berm on the outside
	berm(t, 0, 50, 23.5, 0, math.pi, 24, 5, M.Ground)
	task.wait()

	-- straight B (heading -Z => yaw 0: "along" grows toward -Z)
	local B, yawB = 20, 0
	ramp(t, B, 0, yawB, -35, -29, 0, 1.8, TRACK_W, M.Ground) -- double: kicker (along -35..-29 => z 35..29)
	ramp(t, B, 0, yawB, -21, -19.5, 0, 2.0, TRACK_W, M.Ground) -- landing mound face (case it here)
	ramp(t, B, 0, yawB, -19.5, -11, 2.0, 0, TRACK_W, M.Ground) -- landing
	slab(t, B, -12.5, TRACK_W, 25, 0.06, M.Sand) -- sand section z 0..-25
	ramp(t, B, 0, yawB, 30, 33, 0, 1.4, TRACK_W, M.Ground) -- step-up face (z -30..-33)
	slab(t, B, -37.5, TRACK_W, 9, 1.4, M.Ground) -- plateau
	ramp(t, B, 0, yawB, 42, 48, 1.4, 0, TRACK_W, M.Ground) -- roll-down
	task.wait()

	-- turn 2: mud patch
	slab(t, 0, -70, 12, 8, 0.06, M.Mud)

	-- asphalt pad for supermoto
	slab(t, 55, 0, 24, 100, 0.08, M.Asphalt)
	task.wait()

	-- markers & start. Terrain is voxel-quantised (4 studs), so the real surface is not exactly where the
	-- slabs were asked to end: measure it before placing anything on it.
	local function surfaceY(x, z)
		local res = workspace:Raycast(v(x, 30, z), Vector3.new(0, -60 * S, 0))
		return res and (res.Position.Y / S) or 0
	end
	local gy = surfaceY(A, -44)
	local folder = Instance.new("Folder")
	folder.Name = "RobikesTrack"
	local start = marker(folder, "Start", CFrame.lookAt(v(A, gy + 0.02, -44), v(A, gy + 0.02, 0)), Vector3.new(4, 0.2, 4), Color3.fromRGB(255, 140, 30), Enum.Material.Neon, 0.6)
	start.CanCollide = false
	start.CanQuery = false
	for _, side in ipairs({ -1, 1 }) do
		local px = A + side * (TRACK_W / 2 + 0.3)
		marker(folder, "GatePost", CFrame.new(v(px, surfaceY(px, -41) + 1.2, -41)), Vector3.new(0.6, 2.4, 0.6) * S, Color3.fromRGB(240, 240, 240))
	end
	local banner = marker(folder, "GateBanner", CFrame.new(v(A, gy + 2.5, -41)), Vector3.new(TRACK_W + 1.2, 0.5, 0.1) * S, Color3.fromRGB(255, 140, 30))
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Back
	sg.Parent = banner
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1)
	tl.BackgroundTransparency = 1
	tl.Text = "ROBIKES"
	tl.TextScaled = true
	tl.Font = Enum.Font.GothamBlack
	tl.TextColor3 = Color3.new(1, 1, 1)
	tl.Parent = sg
	folder.Parent = workspace
	return "track built"
end

return TrackBuilder
