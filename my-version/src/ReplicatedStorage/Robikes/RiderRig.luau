--!nonstrict
--[[
	RiderRig — puts the imported R15 rider (ReplicatedStorage.RiderR15, see assets/models/rigged/RIG_TO_ROBLOX.md)
	on the bike and poses it every frame. No Humanoid or Animator is used: every part is anchored and moved in the
	renderer's BulkMoveTo, and each Bone gets a Transform so the skinned mesh bends at the joints.

	Pose = hips placed on the seat, torso leaned forward, two-bone IK for arms (hands to the grips, so they follow the
	steering) and legs (feet to the pegs). All targets are in the renderer's rider space (body-frame studs).

	Works with whatever the 3D Importer produced, as long as the joints are findable by their R15 names
	(Bone "LeftUpperArm", or a Motor6D whose Part1 is "LeftUpperArm"; mesh parts may keep their "_Geo" suffix).
]]

local RiderRig = {}
RiderRig.__index = RiderRig

local SEGMENTS = {
	"LowerTorso", "UpperTorso", "Head",
	"LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot",
}
local IS_SEGMENT = {}
for _, n in ipairs(SEGMENTS) do
	IS_SEGMENT[n] = true
end

local function segmentOf(name)
	name = string.gsub(name, "_Geo$", "")
	return IS_SEGMENT[name] and name or "LowerTorso"
end

-- shortest rotation taking unit vector a to unit vector b
local function rotBetween(a, b)
	local d = a:Dot(b)
	if d > 0.99999 then
		return CFrame.identity
	end
	if d < -0.99999 then
		local axis = math.abs(a.X) < 0.9 and a:Cross(Vector3.xAxis) or a:Cross(Vector3.yAxis)
		return CFrame.fromAxisAngle(axis.Unit, math.pi)
	end
	return CFrame.fromAxisAngle(a:Cross(b).Unit, math.acos(d))
end

-- two-bone IK: root a, segment lengths l1/l2, target t, pole hint p -> middle joint, end joint
local function solveIK(a, l1, l2, t, p)
	local toT = t - a
	local dist = toT.Magnitude
	local dir = dist > 1e-6 and toT / dist or -Vector3.yAxis
	local d = math.clamp(dist, math.abs(l1 - l2) + 1e-3, l1 + l2 - 1e-3)
	local cosA = math.clamp((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d), -1, 1)
	local bend = (p - a) - dir * (p - a):Dot(dir)
	if bend.Magnitude < 1e-6 then
		bend = Vector3.zAxis:Cross(dir)
	end
	bend = bend.Unit
	return a + dir * (l1 * cosA) + bend * (l1 * math.sqrt(1 - cosA * cosA)), a + dir * d
end

-- template: the imported model. parent: the bike model. heightStuds: standing height to scale to.
function RiderRig.new(template, parent, heightStuds)
	local self = setmetatable({}, RiderRig)
	local model = template:Clone()
	if not model:IsA("Model") then
		local wrap = Instance.new("Model")
		model.Parent = wrap
		model = wrap
	end
	model.Name = "Rider"
	local _, size = model:GetBoundingBox()
	if size.Y > 0 then
		model:ScaleTo(model:GetScale() * heightStuds / size.Y)
	end

	-- rest-pose joint positions (world), read before any joint is removed
	local joint = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Bone") and IS_SEGMENT[d.Name] then
			joint[d.Name] = d.WorldPosition
		end
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") and d.Part1 then
			local seg = string.gsub(d.Part1.Name, "_Geo$", "")
			if IS_SEGMENT[seg] and not joint[seg] then
				joint[seg] = (d.Part1.CFrame * d.C1).Position
			end
		end
	end
	for _, n in ipairs(SEGMENTS) do
		if not joint[n] then
			warn("RiderR15 has no joint named " .. n .. "; using the plain-Parts rider instead")
			model:Destroy()
			return nil
		end
	end

	-- rest frame: origin at the hips, X = rider's right, Y = up, Z = back (same axes as the renderer's body frame)
	local up = (joint.Head - joint.LowerTorso).Unit
	local right = joint.RightUpperArm - joint.LeftUpperArm
	right = (right - up * right:Dot(up)).Unit
	local restFrame = CFrame.fromMatrix(joint.LowerTorso, right, up)
	self.rest = {}
	for n, p in pairs(joint) do
		self.rest[n] = restFrame:PointToObjectSpace(p)
	end
	local r = self.rest
	self.len = {}
	for _, s in ipairs({ "Left", "Right" }) do
		self.len[s .. "Arm"] = { (r[s .. "LowerArm"] - r[s .. "UpperArm"]).Magnitude, (r[s .. "Hand"] - r[s .. "LowerArm"]).Magnitude }
		self.len[s .. "Leg"] = { (r[s .. "LowerLeg"] - r[s .. "UpperLeg"]).Magnitude, (r[s .. "Foot"] - r[s .. "LowerLeg"]).Magnitude }
	end

	-- strip everything that would fight the kinematic pose
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("Humanoid") or d:IsA("Script") or d:IsA("LocalScript") or d:IsA("Animator") then
			d:Destroy()
		end
	end

	self.parts = {}
	self.bones = {}
	for _, d in ipairs(model:GetDescendants()) do -- pre-order: parents before children
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			if d.Name == "HumanoidRootPart" then
				d.Transparency = 1
			end
			table.insert(self.parts, { part = d, seg = segmentOf(d.Name), cf = restFrame:ToObjectSpace(d.CFrame) })
		elseif d:IsA("Bone") then
			d.Transform = CFrame.identity
			table.insert(self.bones, { bone = d, seg = segmentOf(d.Name), cf = restFrame:ToObjectSpace(d.WorldCFrame) })
		end
	end
	self.model = model
	self.partWorld = {}
	self.boneWorld = {}
	self.delta = {}
	model.Parent = parent
	return self
end

--[[
	riderBase: rider-space -> world (the renderer's riderBase). t: targets in rider space (studs):
	  hips, torsoLean, hipLean (radians, forward), headUp (radians),
	  gripL/gripR (wrists), elbowL/elbowR (pole hints), ankleL/ankleR, kneeL/kneeR (pole hints)
	put(part, cf): the renderer's BulkMoveTo collector.
]]
function RiderRig:pose(riderBase, t, put)
	local r, delta = self.rest, self.delta
	local function at(pos, rot, restPos)
		return CFrame.new(pos) * rot * CFrame.new(-restPos)
	end

	local rotLT = CFrame.Angles(-t.hipLean, 0, 0)
	delta.LowerTorso = at(t.hips, rotLT, Vector3.zero)
	local waist = delta.LowerTorso * r.UpperTorso
	local restSpine = (r.Head - r.UpperTorso).Unit
	local rotUT = rotBetween(restSpine, (CFrame.Angles(-t.torsoLean, 0, 0) * Vector3.yAxis))
	delta.UpperTorso = at(waist, rotUT, r.UpperTorso)
	delta.Head = at(delta.UpperTorso * r.Head, rotUT * CFrame.Angles(t.headUp, 0, 0), r.Head)

	for _, s in ipairs({ "Left", "Right" }) do
		local k = s == "Left" and "L" or "R"
		-- arm
		local ua, la, h = s .. "UpperArm", s .. "LowerArm", s .. "Hand"
		local shoulder = delta.UpperTorso * r[ua]
		local l = self.len[s .. "Arm"]
		local elbow, wrist = solveIK(shoulder, l[1], l[2], t["grip" .. k], t["elbow" .. k])
		local rotUA = rotBetween(rotUT * (r[la] - r[ua]).Unit, (elbow - shoulder).Unit) * rotUT
		local rotLA = rotBetween(rotUA * (r[h] - r[la]).Unit, (wrist - elbow).Unit) * rotUA
		delta[ua] = at(shoulder, rotUA, r[ua])
		delta[la] = at(elbow, rotLA, r[la])
		delta[h] = at(wrist, rotLA, r[h])
		-- leg
		local ul, ll, f = s .. "UpperLeg", s .. "LowerLeg", s .. "Foot"
		local hip = delta.LowerTorso * r[ul]
		l = self.len[s .. "Leg"]
		local knee, ankle = solveIK(hip, l[1], l[2], t["ankle" .. k], t["knee" .. k])
		local rotUL = rotBetween(rotLT * (r[ll] - r[ul]).Unit, (knee - hip).Unit) * rotLT
		local rotLL = rotBetween(rotUL * (r[f] - r[ll]).Unit, (ankle - knee).Unit) * rotUL
		delta[ul] = at(hip, rotUL, r[ul])
		delta[ll] = at(knee, rotLL, r[ll])
		delta[f] = at(ankle, CFrame.identity, r[f]) -- boots stay level on the pegs
	end

	local partWorld, boneWorld = self.partWorld, self.boneWorld
	for _, it in ipairs(self.parts) do
		local cf = riderBase * delta[it.seg] * it.cf
		partWorld[it.part] = cf
		put(it.part, cf)
	end
	-- bones: Transform = (parent world * rest offset)^-1 * wanted world
	for _, it in ipairs(self.bones) do
		local b = it.bone
		local want = riderBase * delta[it.seg] * it.cf
		local p = b.Parent
		local parentWorld = boneWorld[p] or partWorld[p]
		if parentWorld then
			b.Transform = (parentWorld * b.CFrame):Inverse() * want
		end
		boneWorld[b] = want
	end
end

function RiderRig:destroy()
	self.model:Destroy()
end

return RiderRig
