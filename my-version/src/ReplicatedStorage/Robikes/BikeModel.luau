--!nonstrict
--[[
	BikeModel — drives the imported bike mesh (ReplicatedStorage.Bike450, from assets/models/bike/bike_450_parts.fbx).

	The FBX has six parts that move separately (Frame, Steer, ForkLower, FrontWheel, RearWheel, Swingarm) plus three
	tiny marker cubes (Origin, MarkFwd, MarkUp) 1 m apart in the design frame, so this module can recover position,
	orientation and import scale whatever the importer did. Pivots come from BikeModelData (measured on the mesh by
	tools/split_bike.py). All parts are anchored and placed in the renderer's BulkMoveTo.
]]

local Data = require(script.Parent.BikeModelData)

local BikeModel = {}
BikeModel.__index = BikeModel

local PART_NAMES = { "Frame", "Steer", "ForkLower", "FrontWheel", "RearWheel", "Swingarm" }
local MARKERS = { Origin = true, MarkFwd = true, MarkUp = true }

local function rotBetween(a, b)
	local d = a:Dot(b)
	if d > 0.999999 then
		return CFrame.identity
	end
	return CFrame.fromAxisAngle(a:Cross(b).Unit, math.acos(math.clamp(d, -1, 1)))
end

-- Swap every mesh part's texture for the named colour map from BikeModelData.colourMaps. A SurfaceAppearance would
-- override TextureID, so it is removed. Returns false if that colour has no uploaded map.
function BikeModel:setColour(colour)
	local map = colour and Data.colourMaps[colour]
	if not map or map == "" then
		return false
	end
	for _, it in ipairs(self.parts) do
		local p = it.part
		if p:IsA("MeshPart") then
			local sa = p:FindFirstChildOfClass("SurfaceAppearance")
			if sa then
				sa:Destroy()
			end
			p.TextureID = map
		end
	end
	self.colour = colour
	return true
end

-- template: the imported model. parent: the bike Model. S: studs per metre. com: { forward, up } of the bike spec.
-- colour: optional key of BikeModelData.colourMaps.
function BikeModel.new(template, parent, S, com, colour)
	local self = setmetatable({}, BikeModel)
	local model = template:Clone()
	model.Name = "BikeMesh"
	local function marker(name)
		local m = model:FindFirstChild(name, true)
		return m and m:IsA("BasePart") and m.Position
	end
	local o, f, u = marker("Origin"), marker("MarkFwd"), marker("MarkUp")
	if not (o and f and u) then
		warn("Bike450 is missing its Origin/MarkFwd/MarkUp markers; using the plain-Parts bike instead")
		model:Destroy()
		return nil
	end
	-- 1 m in the design frame should be S studs
	local unit = (f - o).Magnitude
	if math.abs(unit - S) > 1e-3 then
		model:ScaleTo(model:GetScale() * S / unit)
		o, f, u = marker("Origin"), marker("MarkFwd"), marker("MarkUp")
	end
	local fwd = (f - o).Unit
	local up = (u - o) - fwd * (u - o):Dot(fwd)
	up = up.Unit
	local designCF = CFrame.fromMatrix(o, fwd:Cross(up), up) -- X right, Y up, Z back
	-- design frame (studs, origin on the ground under the rear axle) -> body frame (studs, origin at the CoM)
	local bodyFromDesign = CFrame.new(Vector3.new(0, -com[2], com[1]) * S)

	self.S = S
	self.com = com
	self.parts = {}
	local found = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			if MARKERS[d.Name] then
				d:Destroy()
			else
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.Massless = true
				local kind = table.find(PART_NAMES, d.Name) and d.Name or "Frame"
				found[kind] = true
				table.insert(self.parts, { part = d, kind = kind, cf = bodyFromDesign * designCF:ToObjectSpace(d.CFrame) })
			end
		end
	end
	for _, n in ipairs(PART_NAMES) do
		if not found[n] then
			warn("Bike450 has no part named " .. n .. "; it will stay fixed to the frame")
		end
	end

	-- hardpoints in body studs
	local function B(fw, upm, side)
		return Vector3.new(side or 0, upm - com[2], -(fw - com[1])) * S
	end
	self.B = B
	self.axleF0 = B(Data.frontAxle[1], Data.frontAxle[2])
	self.axleR0 = B(Data.rearAxle[1], Data.rearAxle[2])
	self.forkPoint = B(Data.forkPoint[1], Data.forkPoint[2])
	self.forkUp = Vector3.new(0, Data.forkUp[2], -Data.forkUp[1]).Unit
	self.pivot = B(Data.swingarmPivot[1], Data.swingarmPivot[2])
	self.model = model
	self:setColour(colour)
	model.Parent = parent
	return self
end

-- rotation of the steering assembly about the mesh's own fork axis (right = negative about the up-axis)
function BikeModel:steerCF(steer)
	return CFrame.new(self.forkPoint) * CFrame.fromAxisAngle(self.forkUp, -(steer or 0)) * CFrame.new(-self.forkPoint)
end

-- bodyCF: body frame (studs) -> world. spec: the bike spec (wheels[i].mount/radius). put: BulkMoveTo collector.
function BikeModel:update(bodyCF, state, spec, put)
	local S, com = self.S, self.com
	local steerCF = self:steerCF(state.steer)
	local wf, wr = state.wheels[1], state.wheels[2]

	-- front: the physics moves the axle vertically; slide it along this mesh's fork by the same vertical amount
	local fSpec = spec.wheels[1]
	local dy = (fSpec.mount.Y - wf.ext) - (fSpec.radius - com[2]) -- metres above the static position
	local along = dy / math.max(self.forkUp.Y, 0.5)
	local axleF = self.axleF0 + self.forkUp * (along * S)

	-- rear: wheel centre straight from the physics; swingarm swings about its pivot to follow it
	local rSpec = spec.wheels[2]
	local axleR = rSpec.mount * S - Vector3.new(0, wr.ext * S, 0)
	local a0 = self.axleR0 - self.pivot
	local a1 = axleR - self.pivot
	local swing = rotBetween(Vector3.new(0, a0.Y, a0.Z).Unit, Vector3.new(0, a1.Y, a1.Z).Unit)
	local swingCF = CFrame.new(self.pivot) * swing * CFrame.new(-self.pivot)

	local spinF = CFrame.Angles(-(wf.angle or 0), 0, 0)
	local spinR = CFrame.Angles(-(wr.angle or 0), 0, 0)
	for _, it in ipairs(self.parts) do
		local k, cf = it.kind, it.cf
		if k == "Frame" then
			put(it.part, bodyCF * cf)
		elseif k == "Steer" then
			put(it.part, bodyCF * steerCF * cf)
		elseif k == "ForkLower" then
			put(it.part, bodyCF * steerCF * CFrame.new(axleF - self.axleF0) * cf)
		elseif k == "FrontWheel" then
			put(it.part, bodyCF * steerCF * CFrame.new(axleF) * spinF * CFrame.new(-self.axleF0) * cf)
		elseif k == "RearWheel" then
			put(it.part, bodyCF * CFrame.new(axleR) * spinR * CFrame.new(-self.axleR0) * cf)
		elseif k == "Swingarm" then
			put(it.part, bodyCF * swingCF * cf)
		end
	end
end

function BikeModel:destroy()
	self.model:Destroy()
end

return BikeModel
