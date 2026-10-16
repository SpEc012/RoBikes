-- Robikes dev sync: pulls every source file from tools/serve_src.js (127.0.0.1 only) into the open place.
-- Installed as ServerStorage.RobikesDevSync (ModuleScript returning a function). Run in EDIT mode:
--     require(game.ServerStorage.RobikesDevSync)()
-- HTTP is switched on only while syncing and restored afterwards.
-- Rojo-style naming:
--   ReplicatedStorage/Robikes/X.luau                -> ModuleScript X (folder rebuilt fresh each sync)
--   StarterPlayer/StarterPlayerScripts/X.client.luau -> LocalScript X
--   ServerScriptService/X.server.luau               -> Script X
return function()
	local HttpService = game:GetService("HttpService")
	local was = HttpService.HttpEnabled
	HttpService.HttpEnabled = true
	local ok, result = pcall(function()
		local BASE = "http://127.0.0.1:34875"
		local manifest = HttpService:JSONDecode(HttpService:GetAsync(BASE .. "/manifest", true))
		local created, log = 0, {}
		local old = game:GetService("ReplicatedStorage"):FindFirstChild("Robikes")
		if old then
			old:Destroy()
		end
		local function ensureFolder(parent, name)
			local f = parent:FindFirstChild(name)
			if not f then
				f = Instance.new("Folder")
				f.Name = name
				f.Parent = parent
			end
			return f
		end
		for _, entry in ipairs(manifest) do
			local path = entry.path
			local parts = string.split(path, "/")
			local fileName = parts[#parts]
			local className, baseName = "ModuleScript", (fileName:gsub("%.luau?$", ""))
			if fileName:match("%.client%.luau?$") then
				className, baseName = "LocalScript", (fileName:gsub("%.client%.luau?$", ""))
			elseif fileName:match("%.server%.luau?$") then
				className, baseName = "Script", (fileName:gsub("%.server%.luau?$", ""))
			end
			local parent = game:GetService(parts[1])
			for i = 2, #parts - 1 do
				parent = parent:FindFirstChild(parts[i]) or ensureFolder(parent, parts[i])
			end
			local src = HttpService:GetAsync(BASE .. "/file?path=" .. HttpService:UrlEncode(path), true)
			local existing = parent:FindFirstChild(baseName)
			if existing and existing.ClassName ~= className then
				existing:Destroy()
				existing = nil
			end
			local s = existing or Instance.new(className)
			s.Name = baseName
			s.Source = src
			s.Parent = parent
			created += 1
			table.insert(log, s:GetFullName())
		end
		game:GetService("Players").CharacterAutoLoads = false
		return ("synced %d files: %s"):format(created, table.concat(log, ", "))
	end)
	HttpService.HttpEnabled = was
	return (ok and "" or "SYNC FAILED: ") .. tostring(result)
end
