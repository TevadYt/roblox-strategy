--!strict
-- Board camera. "3D" is the war table view: a Scriptable camera orbiting a
-- focus point on the board. "2D" is the strategic map: straight top-down,
-- north up, nearly orthographic, with the 3D dressing hidden. M or the
-- on-screen button toggles between them. The player character is ignored.
-- Left click / tap and Escape belong to territory selection, not to this file.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

export type Mode = "3D" | "2D"

-- Tunables. Distances in studs, angles in degrees, speeds per second.
local CAMERA = GameConfig.Camera

local TAN_3D = math.tan(math.rad(CAMERA.Fov3D) / 2)
local TAN_2D = math.tan(math.rad(CAMERA.Fov2D) / 2)

local player = Players.LocalPlayer
local modeChangedEvent = Instance.new("BindableEvent")

local MapCamera = {}

-- Fires with the new mode whenever it changes.
MapCamera.ModeChanged = modeChangedEvent.Event

type LabelRecord = {
	size: UDim2,
	maxDistance: number,
}

local started = false
local mode: Mode = "3D"

-- What input asks for, and the smoothed values the camera actually uses.
-- Focus is a point on the XZ plane stored as Vector2(x, z).
local targetFocus = Vector2.zero
local focus = Vector2.zero
local targetDistance = CAMERA.StartDistance
local distance = CAMERA.StartDistance
local targetYaw = 0 -- radians; positive turns the view left
local yaw = 0
local targetHalfHeight = CAMERA.BoardHalfZ * CAMERA.Fit2DMargin -- 2D zoom
local halfHeight = targetHalfHeight

-- 0 = 3D, 1 = 2D. Moves linearly over TransitionTime and is eased on use.
local blend = 0

-- The blended view from the last frame, used to turn screen drags into studs.
local viewHalfHeight = CAMERA.StartDistance * TAN_3D
local viewPitch = math.rad(CAMERA.PitchFar)
local viewYaw = 0

local held: { [Enum.KeyCode]: boolean } = {}
local dragButtons: { [Enum.UserInputType]: boolean } = {}
local lastMouse = Vector2.zero
local touches: { [InputObject]: Vector2 } = {}
local touchCount = 0

local map: Model? = nil
local mapConnections: { RBXScriptConnection } = {}
local dressing: { [BasePart]: boolean } = {}
local labels: { [BillboardGui]: LabelRecord } = {}
local dressingFade = 0 -- LocalTransparencyModifier last applied to dressing
local labelsFar = false -- label MaxDistance lifted for the high 2D camera

local toggleButton: TextButton? = nil

local labelTweenInfo = TweenInfo.new(CAMERA.TransitionTime, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Exponential approach, the same feel at any frame rate.
local function damp(current: number, target: number, rate: number, dt: number): number
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

-- Damps in log space so zoom feels even near and far.
local function dampLog(current: number, target: number, rate: number, dt: number): number
	return math.exp(damp(math.log(current), math.log(target), rate, dt))
end

local function ease(t: number): number
	return t * t * (3 - 2 * t)
end

local function clampFocus(point: Vector2): Vector2
	return Vector2.new(
		math.clamp(point.X, -CAMERA.LandHalfX, CAMERA.LandHalfX),
		math.clamp(point.Y, -CAMERA.LandHalfZ, CAMERA.LandHalfZ)
	)
end

-- Pitch below horizontal, easing from cinematic close-ups to map-like far views.
local function pitchFor(dist: number): number
	local t = math.clamp((dist - CAMERA.MinDistance) / (CAMERA.MaxDistance - CAMERA.MinDistance), 0, 1)
	return math.rad(lerp(CAMERA.PitchNear, CAMERA.PitchFar, t))
end

-- 2D half height that fits the whole board on the current screen.
local function fitHalfHeight(): number
	local camera = workspace.CurrentCamera
	local size = if camera then camera.ViewportSize else Vector2.new(16, 9)
	local aspect = if size.Y > 0 then size.X / size.Y else 16 / 9
	return math.max(CAMERA.BoardHalfZ, CAMERA.BoardHalfX / aspect) * CAMERA.Fit2DMargin
end

-- Moves the focus target by studs relative to the view: right, and forward (up the screen).
local function panBy(right: number, forward: number)
	local s, c = math.sin(viewYaw), math.cos(viewYaw)
	local move = Vector2.new(right * c - forward * s, -right * s - forward * c)
	targetFocus = clampFocus(targetFocus + move)
end

-- Drags the board under the pointer by a screen delta in pixels.
local function panByPixels(delta: Vector2)
	local camera = workspace.CurrentCamera
	if not camera or camera.ViewportSize.Y <= 0 then
		return
	end
	local studsPerPixel = 2 * viewHalfHeight / camera.ViewportSize.Y
	-- Tilted ground is squashed vertically on screen, so stretch vertical drags back.
	local tilt = math.max(math.sin(viewPitch), CAMERA.MinTiltFactor)
	panBy(-delta.X * studsPerPixel, delta.Y * studsPerPixel / tilt)
end

-- factor < 1 zooms in.
local function zoomBy(factor: number)
	if mode == "3D" then
		targetDistance = math.clamp(targetDistance * factor, CAMERA.MinDistance, CAMERA.MaxDistance)
	else
		targetHalfHeight = math.clamp(targetHalfHeight * factor, CAMERA.Min2DHalfHeight, fitHalfHeight())
	end
end

local function rotateBy(radians: number)
	if mode == "3D" then
		local limit = math.rad(CAMERA.MaxYaw)
		targetYaw = math.clamp(targetYaw + radians, -limit, limit)
	end
end

local function resetView()
	targetFocus = Vector2.zero
	if mode == "3D" then
		targetDistance = CAMERA.StartDistance
		targetYaw = 0
	else
		targetHalfHeight = fitHalfHeight()
	end
end

local function clearInput()
	table.clear(held)
	table.clear(dragButtons)
	table.clear(touches)
	touchCount = 0
end

-- Dressing and labels ------------------------------------------------------

-- True for parts under a territory's Props folder or Map.Environment.Boats.
local function isDressing(part: BasePart): boolean
	local node = part.Parent
	while node and node ~= map do
		local parent = node.Parent
		if node.Name == "Props" and parent then
			local grand = parent.Parent
			if grand and grand.Name == "Territories" then
				return true
			end
		elseif node.Name == "Boats" and parent and parent.Name == "Environment" then
			return true
		end
		node = parent
	end
	return false
end

local function setDressingFade(fade: number)
	dressingFade = fade
	for part in dressing do
		part.LocalTransparencyModifier = fade
	end
end

local function scaledSize(size: UDim2, scale: number): UDim2
	return UDim2.new(size.X.Scale * scale, size.X.Offset * scale, size.Y.Scale * scale, size.Y.Offset * scale)
end

-- Applies the current mode's size (and distance limit) to one name label.
local function styleLabel(gui: BillboardGui, animate: boolean)
	local record = labels[gui]
	if not record then
		return
	end
	gui.MaxDistance = if labelsFar then math.huge else record.maxDistance
	local size = if mode == "2D" then scaledSize(record.size, CAMERA.LabelScale2D) else record.size
	if animate then
		TweenService:Create(gui, labelTweenInfo, { Size = size }):Play()
	else
		gui.Size = size
	end
end

local function track(instance: Instance)
	if instance:IsA("BasePart") then
		if isDressing(instance) then
			dressing[instance] = true
			if dressingFade > 0 then
				instance.LocalTransparencyModifier = dressingFade
			end
		end
	elseif instance:IsA("BillboardGui") then
		local anchor = instance.Parent
		if anchor and anchor.Name == "Center" and not labels[instance] then
			labels[instance] = { size = instance.Size, maxDistance = instance.MaxDistance }
			styleLabel(instance, false)
		end
	end
end

local function untrack(instance: Instance)
	if instance:IsA("BasePart") then
		dressing[instance] = nil
	elseif instance:IsA("BillboardGui") then
		labels[instance] = nil
	end
end

local function detachMap()
	for _, connection in mapConnections do
		connection:Disconnect()
	end
	table.clear(mapConnections)
	table.clear(dressing)
	table.clear(labels)
	map = nil
end

-- Watches a Map model; parts may keep streaming in after this.
local function attachMap(newMap: Model)
	detachMap()
	map = newMap
	table.insert(mapConnections, newMap.DescendantAdded:Connect(track))
	table.insert(mapConnections, newMap.DescendantRemoving:Connect(untrack))
	table.insert(
		mapConnections,
		newMap.AncestryChanged:Connect(function()
			if map == newMap and not newMap:IsDescendantOf(workspace) then
				detachMap()
			end
		end)
	)
	for _, descendant in newMap:GetDescendants() do
		track(descendant)
	end
end

-- Called once the mode transition has finished.
local function settle()
	setDressingFade(if mode == "2D" then 1 else 0)
	if mode == "3D" then
		labelsFar = false
		for gui, record in labels do
			gui.MaxDistance = record.maxDistance
		end
	end
end

-- Mode ---------------------------------------------------------------------

local function refreshButton()
	local button = toggleButton
	if not button then
		return
	end
	if mode == "3D" then
		button.Text = '<b>3D</b> / <font color="#8c8c8c">2D</font>'
	else
		button.Text = '<font color="#8c8c8c">3D</font> / <b>2D</b>'
	end
end

function MapCamera.getMode(): Mode
	return mode
end

function MapCamera.setMode(newMode: Mode)
	if newMode == mode then
		return
	end
	mode = newMode
	if mode == "2D" then
		labelsFar = true
		if CAMERA.Fit2DOnEnter then
			targetHalfHeight = fitHalfHeight()
			targetFocus = Vector2.zero
		end
		-- The blend animates the move; start the 2D zoom already settled.
		halfHeight = targetHalfHeight
	end
	for gui in labels do
		styleLabel(gui, true)
	end
	refreshButton()
	modeChangedEvent:Fire(mode)
end

local function toggleMode()
	MapCamera.setMode(if mode == "3D" then "2D" else "3D")
end

-- Per frame ----------------------------------------------------------------

local function axis(plus: Enum.KeyCode, plusAlt: Enum.KeyCode, minus: Enum.KeyCode, minusAlt: Enum.KeyCode): number
	local value = 0
	if held[plus] or held[plusAlt] then
		value += 1
	end
	if held[minus] or held[minusAlt] then
		value -= 1
	end
	return value
end

local function step(frameDt: number)
	local dt = math.min(frameDt, 0.1)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	-- Something (character spawn, PlayerModule) may reset this; keep ours.
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	-- Keyboard pan and rotate.
	local right = axis(Enum.KeyCode.D, Enum.KeyCode.Right, Enum.KeyCode.A, Enum.KeyCode.Left)
	local forward = axis(Enum.KeyCode.W, Enum.KeyCode.Up, Enum.KeyCode.S, Enum.KeyCode.Down)
	if right ~= 0 or forward ~= 0 then
		local speed = CAMERA.PanKeySpeed * viewHalfHeight * dt / math.sqrt(right * right + forward * forward)
		panBy(right * speed, forward * speed)
	end
	local turn = axis(Enum.KeyCode.Q, Enum.KeyCode.Q, Enum.KeyCode.E, Enum.KeyCode.E)
	if turn ~= 0 then
		rotateBy(turn * math.rad(CAMERA.YawKeySpeed) * dt)
	end

	-- Smooth towards the targets.
	focus = focus:Lerp(targetFocus, 1 - math.exp(-CAMERA.FocusDamping * dt))
	distance = dampLog(distance, targetDistance, CAMERA.ZoomDamping, dt)
	halfHeight = dampLog(halfHeight, targetHalfHeight, CAMERA.ZoomDamping, dt)
	yaw = damp(yaw, targetYaw, CAMERA.YawDamping, dt)

	-- Mode transition.
	local goal = if mode == "2D" then 1 else 0
	if blend ~= goal then
		local amount = dt / CAMERA.TransitionTime
		blend = if goal > blend then math.min(blend + amount, 1) else math.max(blend - amount, 0)
		if blend == goal then
			settle()
		end
	end
	local t = ease(blend)

	-- Blend both views as a dolly zoom: interpolate the visible half height and
	-- the lens in log space, then derive the camera distance from them.
	local halfHeight3D = distance * TAN_3D
	local tanHalfFov = TAN_3D * (TAN_2D / TAN_3D) ^ t
	viewHalfHeight = halfHeight3D * (halfHeight / halfHeight3D) ^ t
	viewPitch = lerp(pitchFor(distance), math.pi / 2, t)
	viewYaw = lerp(yaw, 0, t)

	local pivot = CFrame.new(focus.X, CAMERA.FocusY, focus.Y)
	camera.FieldOfView = math.deg(2 * math.atan(tanHalfFov))
	camera.CFrame = pivot
		* CFrame.Angles(0, viewYaw, 0)
		* CFrame.Angles(-viewPitch, 0, 0)
		* CFrame.new(0, 0, viewHalfHeight / tanHalfFov)
	camera.Focus = pivot

	-- Fade the 3D dressing along with the transition.
	if blend ~= goal and math.abs(t - dressingFade) > 0.02 then
		setDressingFade(t)
	end
end

-- Input --------------------------------------------------------------------

-- Keys go through ContextActionService above the default character controls
-- and are sunk, so WASD and arrows never walk the character. CAS does not fire
-- while a TextBox has focus.
local function onKey(_: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local key = input.KeyCode
	if state == Enum.UserInputState.Begin then
		held[key] = true
		if key == Enum.KeyCode.M then
			toggleMode()
		elseif key == Enum.KeyCode.R then
			resetView()
		end
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		held[key] = nil
	end
	return Enum.ContextActionResult.Sink
end

local function bindInput()
	local priority = Enum.ContextActionPriority.High.Value
	ContextActionService:BindActionAtPriority(
		"MapCameraPan",
		onKey,
		false,
		priority,
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
		Enum.KeyCode.Up,
		Enum.KeyCode.Down,
		Enum.KeyCode.Left,
		Enum.KeyCode.Right
	)
	ContextActionService:BindActionAtPriority("MapCameraRotate", onKey, false, priority, Enum.KeyCode.Q, Enum.KeyCode.E)
	ContextActionService:BindActionAtPriority("MapCameraReset", onKey, false, priority, Enum.KeyCode.R)
	ContextActionService:BindActionAtPriority("MapCameraToggle", onKey, false, priority, Enum.KeyCode.M)

	-- Right or middle mouse drag pans; the wheel zooms.
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton2 or kind == Enum.UserInputType.MouseButton3 then
			dragButtons[kind] = true
			lastMouse = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		dragButtons[input.UserInputType] = nil
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseMovement then
			-- Once a drag has started, keep it even when the pointer crosses GUI.
			if next(dragButtons) == nil then
				return
			end
			local position = Vector2.new(input.Position.X, input.Position.Y)
			local delta = position - lastMouse
			lastMouse = position
			if delta.Magnitude < 1e-3 then
				-- The mouse is locked in place; fall back to the raw delta.
				delta = Vector2.new(input.Delta.X, input.Delta.Y)
			end
			panByPixels(delta)
		elseif kind == Enum.UserInputType.MouseWheel and not processed then
			zoomBy(CAMERA.ZoomStep ^ input.Position.Z)
		end
	end)

	-- Touch: one finger pans, two fingers pinch zoom, twist rotate and pan
	-- together. Nothing is sunk, so TouchTap still reaches selection.
	UserInputService.TouchStarted:Connect(function(input: InputObject, processed: boolean)
		if processed or touches[input] then
			return
		end
		touches[input] = Vector2.new(input.Position.X, input.Position.Y)
		touchCount += 1
	end)

	UserInputService.TouchMoved:Connect(function(input: InputObject)
		local last = touches[input]
		if not last then
			return
		end
		local position = Vector2.new(input.Position.X, input.Position.Y)
		touches[input] = position
		if touchCount == 1 then
			panByPixels(position - last)
		elseif touchCount == 2 then
			local other: Vector2? = nil
			for touch, touchPosition in touches do
				if touch ~= input then
					other = touchPosition
				end
			end
			if not other then
				return
			end
			local before = last - other
			local after = position - other
			if before.Magnitude > 1 and after.Magnitude > 1 then
				zoomBy(before.Magnitude / after.Magnitude)
				local twist = math.atan2(after.Y, after.X) - math.atan2(before.Y, before.X)
				rotateBy((twist + math.pi) % (2 * math.pi) - math.pi)
			end
			-- The midpoint moves half as far as the finger that moved.
			panByPixels((position - last) / 2)
		end
	end)

	UserInputService.TouchEnded:Connect(function(input: InputObject)
		if touches[input] then
			touches[input] = nil
			touchCount -= 1
		end
	end)

	-- Don't leave keys stuck down when focus moves away.
	UserInputService.WindowFocusReleased:Connect(clearInput)
	UserInputService.TextBoxFocused:Connect(function()
		table.clear(held)
	end)
end

-- HUD ----------------------------------------------------------------------

local function createHud()
	local gui = Instance.new("ScreenGui")
	gui.Name = "MapCameraHud"
	gui.ResetOnSpawn = false

	local button = Instance.new("TextButton")
	button.Name = "ModeToggle"
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -16, 1, -16)
	button.Size = UDim2.fromOffset(96, 40)
	button.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	button.BackgroundTransparency = 0.25
	button.RichText = true
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	button.Activated:Connect(toggleMode)
	toggleButton = button
	refreshButton()

	task.spawn(function()
		gui.Parent = player:WaitForChild("PlayerGui")
	end)
end

-- Start --------------------------------------------------------------------

function MapCamera.start()
	if started then
		return
	end
	started = true

	targetHalfHeight = fitHalfHeight()
	halfHeight = targetHalfHeight
	if CAMERA.HideTouchControls then
		GuiService.TouchControlsEnabled = false
	end

	createHud()
	bindInput()
	RunService:BindToRenderStep("MapCamera", Enum.RenderPriority.Camera.Value + 1, step)

	-- The map is built by the server and may arrive after us, or be rebuilt.
	local existing = workspace:FindFirstChild("Map")
	if existing and existing:IsA("Model") then
		attachMap(existing)
	end
	workspace.ChildAdded:Connect(function(child: Instance)
		if child.Name == "Map" and child:IsA("Model") then
			attachMap(child)
		end
	end)
end

return MapCamera
