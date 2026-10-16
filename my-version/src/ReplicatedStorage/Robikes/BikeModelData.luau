--!nonstrict
-- Hardpoints of assets/models/bike/bike_450_parts.fbx, measured on the mesh by tools/split_bike.py.
-- Design frame (metres): (forward, up), origin = ground under the rear axle at static sag; side + = rider's right.
-- Re-run the tool and copy its bike_450_parts.json here if the mesh changes.
return {
	frontAxle = { 1.47, 0.335 },
	rearAxle = { 0.0, 0.325 },
	-- steering axis = the fork-tube line: a point on it and its unit direction (forward, up), pointing up the fork
	forkPoint = { 1.2575, 0.7481 },
	forkUp = { -0.3792, 0.9253 }, -- 22.3° from vertical
	swingarmPivot = { 0.48, 0.42 },
	-- where the rider holds on and sits
	grip = { 0.911, 1.246, 0.412 }, -- (forward, up, |side|) of the bar ends
	seatTop = 0.999,
	-- colour maps uploaded to Roblox (assets/models/bike/colours/bike_450_colour_<name>.png). "" = not uploaded yet,
	-- in which case the bike keeps the texture it was imported with.
	colourMaps = {
		orange = "rbxassetid://129915470649500",
		red = "",
		blue = "",
		green = "",
		yellow = "",
		purple = "",
		black = "",
	},
}
