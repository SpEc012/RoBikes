--[[
	Pacejka  —  simplified Magic Formula tyre forces (game-stable form).
	Reproduces the MX Bikes tyre behaviour from .tyre coefficients without the full MF6.1 maths:
	one combined longitudinal/lateral solve with a friction ellipse. All SI.

	Reference MF curve:  F = D * sin( C * atan( B*s - E*(B*s - atan(B*s)) ) )
	  D = peak force (mu * Fz),  B = stiffness,  C = shape,  E = curvature,  s = slip.
]]

local Pacejka = {}

local function magic(slip, B, C, D, E)
	local x = B * slip
	return D * math.sin(C * math.atan(x - E * (x - math.atan(x))))
end
Pacejka.magic = magic

-- Load sensitivity: grip coefficient falls as vertical load rises above nominal Fz0.
local function loadFactor(Fz, Fz0, falloff)
	local dfz = (Fz - Fz0) / Fz0
	return math.max(0.4, 1.0 - falloff * dfz)
end

--[[
	solve(tyre, Fz, surfaceGrip, kappa, alpha)
	  tyre         : a Config.Tyres entry
	  Fz           : vertical load on this tyre (N, >=0)
	  surfaceGrip  : multiplier from the surface under the contact patch
	  kappa        : longitudinal slip ratio  (wheelSurfaceSpeed - groundFwd)/|groundFwd|
	  alpha        : slip angle (rad)
	returns Fx (forward, N), Fy (lateral, N)  already limited by the friction ellipse.
]]
function Pacejka.solve(tyre, Fz, surfaceGrip, kappa, alpha)
	if Fz <= 0 then return 0, 0 end
	local lf = loadFactor(Fz, tyre.Fz0, tyre.loadFalloff)
	local muX = tyre.muX * surfaceGrip * lf
	local muY = tyre.muY * surfaceGrip * lf
	local Dx = muX * Fz
	local Dy = muY * Fz

	-- B is derived so the curve's initial slope matches the slip stiffness K.
	local Bx = (tyre.Cx * Dx > 1e-6) and (tyre.Kx * Fz) / (tyre.Cx * Dx) or tyre.Kx
	local By = (tyre.Cy * Dy > 1e-6) and (tyre.Ky * Fz) / (tyre.Cy * Dy) or tyre.Ky

	local Fx = magic(kappa, Bx, tyre.Cx, Dx, tyre.Ex)
	local Fy = magic(alpha, By, tyre.Cy, Dy, tyre.Ey)

	-- Friction ellipse: can't exceed combined grip. Scale both down if over budget.
	local maxX, maxY = Dx, Dy
	if maxX > 1e-6 and maxY > 1e-6 then
		local e = (Fx / maxX)^2 + (Fy / maxY)^2
		if e > 1 then
			local s = 1 / math.sqrt(e)
			Fx, Fy = Fx * s, Fy * s
		end
	end
	return Fx, Fy
end

return Pacejka
