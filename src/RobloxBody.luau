--!nonstrict
-- WSI.RobloxBody: the physical side of a character in Roblox, ready to hand
-- to WSI.World as a body. It makes (or adopts) an R15 rig and gives it idle
-- and walk animations, pathfinding, emotes, a filtered speech bubble, and a
-- status line over its head.
--
--   local body = WSI.RobloxBody.new({ name = "Mia", position = Vector3.new(0, 0, 0) })
--   local body = WSI.RobloxBody.new({ name = "Mia", model = workspace.MiaRig })

local BUBBLE_SECONDS = 7
local ANIMATIONS = {
	idle = "rbxassetid://507766666",
	walk = "rbxassetid://507777826",
	wave = "rbxassetid://507770239",
	point = "rbxassetid://507770453",
	dance = "rbxassetid://507771019",
	laugh = "rbxassetid://507770818",
	cheer = "rbxassetid://507770677",
}

local RobloxBody = {}
RobloxBody.__index = RobloxBody

export type Options = {
	name: string,
	-- An existing rig with a Humanoid. Without it a rig is built.
	model: Model?,
	-- Ground position for a built rig.
	position: Vector3?,
	faces: Vector3?,
	-- Looks for a built rig. A HumanoidDescription wins over colors.
	description: HumanoidDescription?,
	colors: { skin: Color3?, shirt: Color3?, pants: Color3? }?,
	parent: Instance?,
	walkSpeed: number?,
}

local function buildModel(options: Options): Model
	local Players = game:GetService("Players")
	local description = options.description
	if not description then
		description = Instance.new("HumanoidDescription")
		local colors = options.colors or {}
		local skin = colors.skin or Color3.fromRGB(234, 184, 146)
		local shirt = colors.shirt or Color3.fromRGB(70, 130, 180)
		local pants = colors.pants or Color3.fromRGB(50, 60, 80)
		description.HeadColor = skin
		description.LeftArmColor = skin
		description.RightArmColor = skin
		description.TorsoColor = shirt
		description.LeftLegColor = pants
		description.RightLegColor = pants
	end
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	model.Name = options.name
	return model
end

function RobloxBody.new(options: Options)
	local model = options.model
	local built = model == nil
	if not model then
		local parent = options.parent or workspace
		local old = parent:FindFirstChild(options.name)
		if old then
			old:Destroy()
		end
		model = buildModel(options)
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = model:WaitForChild("HumanoidRootPart") :: BasePart
	local head = model:WaitForChild("Head") :: BasePart
	humanoid.DisplayName = options.name
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.NameDisplayDistance = 70
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	if options.walkSpeed then
		humanoid.WalkSpeed = options.walkSpeed
	end

	if built then
		local standHeight = humanoid.HipHeight + root.Size.Y / 2
		local position = (options.position or Vector3.zero) + Vector3.new(0, standHeight, 0)
		local faces = options.faces or (position + Vector3.new(0, 0, -1))
		model:PivotTo(CFrame.lookAt(position, Vector3.new(faces.X, position.Y, faces.Z)))
		model.Parent = options.parent or workspace
	end
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	local self = setmetatable({
		name = options.name,
		model = model,
		humanoid = humanoid,
		root = root,
		head = head,
		walking = false,
		emotes = { "wave", "laugh", "cheer", "dance", "point" },
		_walkToken = 0,
		_bubbleToken = 0,
		_tracks = {},
	}, RobloxBody)
	self:_animate()
	self:_buildOverhead()
	return self
end

function RobloxBody:_track(name: string): AnimationTrack?
	if self._tracks[name] then
		return self._tracks[name]
	end
	local id = ANIMATIONS[name]
	if not id then
		return nil
	end
	local animator = self.humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", self.humanoid)
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local track = animator:LoadAnimation(animation)
	self._tracks[name] = track
	return track
end

function RobloxBody:_animate()
	local idle, walk = self:_track("idle"), self:_track("walk")
	idle.Looped = true
	walk.Looped = true
	idle:Play()
	self.humanoid.Running:Connect(function(speed)
		if speed > 0.5 then
			if not walk.IsPlaying then
				idle:Stop(0.2)
				walk:Play(0.2)
			end
		elseif walk.IsPlaying then
			walk:Stop(0.2)
			idle:Play(0.2)
		end
	end)
end

function RobloxBody:_buildOverhead()
	local bubble = Instance.new("BillboardGui")
	bubble.Name = "SpeechBubble"
	bubble.Size = UDim2.fromOffset(280, 96)
	bubble.StudsOffset = Vector3.new(0, 4.4, 0)
	bubble.MaxDistance = 90
	bubble.Enabled = false
	bubble.Adornee = self.head
	bubble.Parent = self.head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	label.TextColor3 = Color3.fromRGB(25, 25, 25)
	label.Font = Enum.Font.BuilderSansMedium
	label.TextScaled = true
	label.TextWrapped = true
	label.Parent = bubble
	Instance.new("UICorner", label).CornerRadius = UDim.new(0, 12)
	local padding = Instance.new("UIPadding", label)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	local limit = Instance.new("UITextSizeConstraint", label)
	limit.MaxTextSize = 22

	local status = Instance.new("BillboardGui")
	status.Name = "Status"
	status.Size = UDim2.fromOffset(220, 22)
	status.StudsOffset = Vector3.new(0, 2.4, 0)
	status.MaxDistance = 60
	status.Enabled = false
	status.Adornee = self.head
	status.Parent = self.head
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.fromScale(1, 1)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	statusLabel.TextStrokeTransparency = 0.4
	statusLabel.Font = Enum.Font.BuilderSans
	statusLabel.TextScaled = true
	statusLabel.Parent = status

	self._bubble = bubble
	self._label = label
	self._status = status
	self._statusLabel = statusLabel
end

function RobloxBody:getPosition(): Vector3
	return self.root.Position
end

function RobloxBody:setStatus(text: string?)
	if text and text ~= "" then
		self._statusLabel.Text = text
		self._status.Enabled = true
	else
		self._status.Enabled = false
	end
end

function RobloxBody:face(position: Vector3)
	local root = self.root
	local flat = Vector3.new(position.X, root.Position.Y, position.Z)
	if (flat - root.Position).Magnitude > 0.1 and not self.walking then
		root.CFrame = CFrame.lookAt(root.Position, flat)
	end
end

function RobloxBody:_nearestPlayer(): Player?
	local Players = game:GetService("Players")
	local best, bestDistance = nil, math.huge
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local part = character and character:FindFirstChild("HumanoidRootPart")
		local d = part and (part.Position - self.root.Position).Magnitude or math.huge
		if d < bestDistance or not best then
			best, bestDistance = player, d
		end
	end
	return best
end

--- Show a line in the speech bubble and return the filtered text. Roblox
--- requires text shown to players to be filtered.
function RobloxBody:say(text: string, facePosition: Vector3?): string
	text = string.sub(text, 1, 240)
	local shown = text
	local who = self:_nearestPlayer()
	if who then
		local ok, result = pcall(function()
			local filtered = game:GetService("TextService"):FilterStringAsync(text, who.UserId, Enum.TextFilterContext.PublicChat)
			return filtered:GetNonChatStringForBroadcastAsync()
		end)
		if not ok then
			error("that line could not be shown; say something else", 0)
		end
		shown = result
	end
	if facePosition then
		self:face(facePosition)
	end
	self._bubbleToken += 1
	local token = self._bubbleToken
	self._label.Text = shown
	self._bubble.Enabled = true
	task.delay(math.clamp(2.5 + #shown / 18, 3, BUBBLE_SECONDS + 3), function()
		if self._bubbleToken == token then
			self._bubble.Enabled = false
		end
	end)
	return shown
end

--- Show a thinking bubble until the next say, or hide it.
function RobloxBody:setThinking(on: boolean)
	if on and not self._bubble.Enabled then
		self._bubbleToken += 1
		self._label.Text = "..."
		self._bubble.Enabled = true
		self._thinking = self._bubbleToken
	elseif not on and self._thinking == self._bubbleToken then
		self._bubble.Enabled = false
	end
end

function RobloxBody:emote(name: string)
	local track = self:_track(name)
	if not track then
		return
	end
	track.Looped = false
	track:Play(0.2)
	task.delay(3, function()
		track:Stop(0.3)
	end)
end

function RobloxBody:stop()
	self._walkToken += 1
	self.walking = false
	self.humanoid:MoveTo(self.root.Position)
end

-- A goal's center is often inside a prop. Try it, then spots around it.
function RobloxBody:_findPath(goal: Vector3): ({ PathWaypoint }?, Vector3)
	local PathfindingService = game:GetService("PathfindingService")
	local candidates = { goal }
	for _, radius in { 4, 8 } do
		for step = 0, 5 do
			local angle = step * math.pi / 3
			table.insert(candidates, goal + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
		end
	end
	for _, target in candidates do
		local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
		local ok = pcall(function()
			path:ComputeAsync(self.root.Position, target)
		end)
		if ok and path.Status == Enum.PathStatus.Success then
			return path:GetWaypoints(), target
		end
	end
	return nil, goal
end

--- Walk to a position. Yields until arrival, stop(), or another moveTo().
--- Returns true when it ended close to the goal.
function RobloxBody:moveTo(goal: Vector3): boolean
	self._walkToken += 1
	local token = self._walkToken
	self.walking = true
	local waypoints, target = self:_findPath(goal)
	if self._walkToken ~= token then
		return false
	end
	if not waypoints then
		waypoints = { { Position = target, Action = Enum.PathWaypointAction.Walk } }
	end
	for _, waypoint in waypoints do
		if self._walkToken ~= token then
			return false
		end
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			self.humanoid.Jump = true
		end
		self.humanoid:MoveTo(waypoint.Position)
		local arrived = false
		local connection = self.humanoid.MoveToFinished:Once(function()
			arrived = true
		end)
		local started = os.clock()
		while not arrived and os.clock() - started < 6 and self._walkToken == token do
			task.wait(0.1)
		end
		connection:Disconnect()
	end
	if self._walkToken ~= token then
		return false
	end
	self.walking = false
	local flat = Vector3.new(target.X, self.root.Position.Y, target.Z)
	return (flat - self.root.Position).Magnitude < 9
end

function RobloxBody:destroy()
	self._walkToken += 1
	self.model:Destroy()
end

return RobloxBody
