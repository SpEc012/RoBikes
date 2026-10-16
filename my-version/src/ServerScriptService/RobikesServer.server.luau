--!nonstrict
--[[
	RobikesServer — players ride Robikes bikes instead of avatars. Each client runs its own bike physics
	(client-authoritative, like MX Bikes' own netcode model) and sends ~15 Hz states; the server
	sanity-checks and relays them to everyone else.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

Players.CharacterAutoLoads = false -- the bike's own rider replaces the avatar

local Robikes = ReplicatedStorage:WaitForChild("Robikes")
local net = Robikes:FindFirstChild("Net") or Instance.new("Folder")
net.Name = "Net"
net.Parent = Robikes

local stateEvent = net:FindFirstChild("BikeState") or Instance.new("UnreliableRemoteEvent")
stateEvent.Name = "BikeState"
stateEvent.Parent = net
local leftEvent = net:FindFirstChild("BikeLeft") or Instance.new("RemoteEvent")
leftEvent.Name = "BikeLeft"
leftEvent.Parent = net

local MAX_RATE = 30 -- packets per second per player
local MAX_SPEED = 90 -- m/s; anything faster between packets (that isn't a respawn) is dropped
local last = {}

stateEvent.OnServerEvent:Connect(function(player, packet)
	if type(packet) ~= "table" or typeof(packet.cf) ~= "CFrame" or type(packet.w) ~= "table" then
		return
	end
	local now = os.clock()
	local rec = last[player]
	if rec and now - rec.t < 1 / MAX_RATE then
		return
	end
	local p = packet.cf.Position
	if p.Magnitude > 1e4 or p ~= p then
		return
	end
	if rec then
		local speed = (p - rec.p).Magnitude / math.max(now - rec.t, 1e-3)
		if speed > MAX_SPEED and (p - rec.p).Magnitude < 25 then
			return -- implausible jump that isn't a respawn teleport
		end
	end
	last[player] = { t = now, p = p }
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			stateEvent:FireClient(other, player.UserId, packet)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	last[player] = nil
	leftEvent:FireAllClients(player.UserId)
end)
