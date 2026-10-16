--!nonstrict
--[[
	Tyre — Pacejka "Magic Formula", motorcycle form (pure Luau, SI).

	Inputs: MF coefficient table from the .tyre data (names kept: p_Cx1, p_Dx1, ... ), vertical load Fz (N),
	slip ratio kappa, slip angle alpha (rad, + = contact patch sliding to the right), camber gamma
	(rad, + = leaning right) and the surface grip multiplier mu.
	Output: Fx (forward, N) and Fy (+ = to the right, N).

	Formula reference (public): Pacejka, "Tire and Vehicle Dynamics", motorcycle MF with a separate camber
	term inside the sine (coefficients p_Cy2 / p_Ky6 / p_Ey5 present in the data). [INF — see REPORT §3]
]]

local Tyre = {}

local atan, sin, cos, abs, max, min, exp = math.atan, math.sin, math.cos, math.abs, math.max, math.min, math.exp

local function sgn(x)
	return x > 0 and 1 or (x < 0 and -1 or 0)
end

-- core curve: D * sin(C * atan(B*x - E*(B*x - atan(B*x))))
local function mf(B, C, D, E, x)
	local bx = B * x
	return D * sin(C * atan(bx - E * (bx - atan(bx))))
end
Tyre.mf = mf

-- Pure longitudinal force (before combined-slip weighting)
function Tyre.pureFx(p, Fz, kappa, mu)
	if Fz <= 0 then
		return 0
	end
	local Fz0 = p.Fz0 or 1000
	local dfz = (Fz - Fz0) / Fz0
	local Cx = p.p_Cx1 or 1.5
	local muX = max(0.05, (p.p_Dx1 or 1) + (p.p_Dx2 or 0) * dfz) * mu
	local Dx = muX * Fz
	local Kx = Fz * ((p.p_Kx1 or 20) + (p.p_Kx2 or 0) * dfz) * exp((p.p_Kx3 or 0) * dfz)
	local Bx = Kx / (Cx * Dx + 1e-9)
	local Ex = min(1, (p.p_Ex1 or 0) + (p.p_Ex2 or 0) * dfz + (p.p_Ex3 or 0) * dfz * dfz) * (1 - (p.p_Ex4 or 0) * sgn(kappa))
	return mf(Bx, Cx, Dx, Ex, kappa)
end

-- Pure lateral force with camber thrust (motorcycle MF). Positive = to the right.
function Tyre.pureFy(p, Fz, alpha, gamma, mu)
	if Fz <= 0 then
		return 0
	end
	local Fz0 = p.Fz0 or 1000
	local dfz = (Fz - Fz0) / Fz0
	local Cy = p.p_Cy1 or 1.2
	local muY = max(0.05, (p.p_Dy1 or 1) + (p.p_Dy2 or 0) * dfz) * mu
	local Dy = muY * Fz
	local Kya = (p.p_Ky1 or 20) * Fz0 * sin(2 * atan(Fz / ((p.p_Ky2 or 1) * Fz0))) * (1 - (p.p_Ky3 or 0) * abs(gamma))
	local Kyg = Fz * ((p.p_Ky6 or 0) + (p.p_Ky7 or 0) * dfz)
	local By = Kya / (Cy * Dy + 1e-9)
	local Cg = p.p_Cy2 or 0
	local Bg = (Cg > 0) and (Kyg / (Cg * Dy + 1e-9)) or 0
	local Ey = p.p_Ey1 or 0
	local Eg = p.p_Ey5 or 0
	local a = -alpha -- sliding right -> force to the left
	local ba = By * a
	local bg = Bg * gamma
	local inner = Cy * atan(ba - Ey * (ba - atan(ba))) + Cg * atan(bg - Eg * (bg - atan(bg)))
	-- past the peak the force drops (that's the slide), but slip + camber summed inside the sine could fold
	-- it back to near zero; cap the argument so a fully sliding tyre keeps >= ~90% of peak [DESIGN]
	inner = math.clamp(inner, -2.0, 2.0)
	return Dy * sin(inner)
end

-- Combined-slip weights (MF r_ coefficients). Both in [0, 1].
function Tyre.weights(p, kappa, alpha)
	local Bxa = (p.r_Bx1 or 0) * cos(atan((p.r_Bx2 or 0) * kappa))
	local Gxa = cos((p.r_Cx1 or 1) * atan(Bxa * alpha))
	local Byk = (p.r_By1 or 0) * cos(atan((p.r_By2 or 0) * (alpha - (p.r_By3 or 0))))
	local Gyk = cos((p.r_Cy1 or 1) * atan(Byk * kappa))
	return max(0, Gxa), max(0, Gyk)
end

-- Full combined forces
function Tyre.forces(p, Fz, kappa, alpha, gamma, mu)
	if Fz <= 0 then
		return 0, 0
	end
	local Gxa, Gyk = Tyre.weights(p, kappa, alpha)
	return Tyre.pureFx(p, Fz, kappa, mu) * Gxa, Tyre.pureFy(p, Fz, alpha, gamma, mu) * Gyk
end

-- Longitudinal force and its slope dFx/dkappa (for the implicit wheel-spin solve).
function Tyre.fxAndSlope(p, Fz, kappa, alpha, mu)
	if Fz <= 0 then
		return 0, 0
	end
	local h = 1e-3
	local Gxa = Tyre.weights(p, kappa, alpha)
	local f0 = Tyre.pureFx(p, Fz, kappa, mu) * Gxa
	local fp = Tyre.pureFx(p, Fz, kappa + h, mu) * Gxa
	local fm = Tyre.pureFx(p, Fz, kappa - h, mu) * Gxa
	return f0, max(0, (fp - fm) / (2 * h))
end

-- Rolling-resistance coefficient (q_sy1) [INF]
function Tyre.rollingCoeff(p)
	return p.q_sy1 or 0.02
end

return Tyre
