-- Connected Discord-GitHub
--!strict

--[[
	sentinel grid is a small stealth simulation built from roblox primitives
	the server owns the maze drones objectives and completion state
	the client only receives the presentation data it needs for the hud
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")

-- keeping the tuning values together makes each system easy to rebalance
local CONFIG = {
	DefaultSeed = 314159,
	GridSize = 9,
	CellSize = 14,
	WallHeight = 12,
	WallThickness = 1,
	ExtraLoopChance = 0.09,
	RequiredCores = 3,
	DroneCount = 2,
	DroneSpeed = 10,
	VisionRange = 58,
	VisionHalfAngle = math.rad(50),
	HearingRange = 18,
	HearingSpeed = 11,
	SuspicionGain = 0.9,
	HearingGain = 0.28,
	SuspicionDecay = 0.34,
	PathRefresh = 0.45,
	SearchDuration = 4.5,
	CaptureDistance = 3.6,
	CaptureRecovery = 0.35,
	CaptureProtection = 1.5,
	PromptDistance = 10,
	PromptCooldown = 0.25,
	SnapshotRate = 0.1,
}

local COLORS = {
	Floor = Color3.fromRGB(30, 34, 31),
	Wall = Color3.fromRGB(56, 62, 56),
	Core = Color3.fromRGB(229, 166, 63),
	Drone = Color3.fromRGB(224, 69, 62),
	Exit = Color3.fromRGB(224, 224, 211),
	Locked = Color3.fromRGB(139, 52, 49),
}

type Cell = { x: number, z: number }
type MazeCell = {
	North: boolean,
	East: boolean,
	South: boolean,
	West: boolean,
	Visited: boolean,
}
type Maze = { [number]: { [number]: MazeCell } }
type PlayerState = {
	collected: number,
	status: string,
	startedAt: number,
	lastPromptAt: number,
	invulnerableUntil: number,
	capturing: boolean,
}
type HeapEntry = { cell: Cell, priority: number }

local DirectionData = {
	{ name = "North", opposite = "South", dx = 0, dz = -1 },
	{ name = "East", opposite = "West", dx = 1, dz = 0 },
	{ name = "South", opposite = "North", dx = 0, dz = 1 },
	{ name = "West", opposite = "East", dx = -1, dz = 0 },
}

local sentinelEvent = ReplicatedStorage:FindFirstChild("SentinelEvent") :: RemoteEvent?
if not sentinelEvent then
	sentinelEvent = Instance.new("RemoteEvent")
	sentinelEvent.Name = "SentinelEvent"
	sentinelEvent.Parent = ReplicatedStorage
end

local currentSeed = CONFIG.DefaultSeed
local currentMaze: Maze? = nil
local worldFolder: Folder? = nil
local mapFolder: Folder? = nil
local objectiveFolder: Folder? = nil
local droneFolder: Folder? = nil
local effectFolder: Folder? = nil
local startCell: Cell = { x = 1, z = 1 }
local exitCell: Cell = { x = CONFIG.GridSize, z = CONFIG.GridSize }
local coreCells: { Cell } = {}
local patrolCells: { Cell } = {}
local playerStates: { [Player]: PlayerState } = {}
local worldConnections: { RBXScriptConnection } = {}
local drones: { any } = {}
local exitDoor: BasePart? = nil
local exitPrompt: ProximityPrompt? = nil
local restartPrompt: ProximityPrompt? = nil
local exitOpened = false
local rebuilding = false
local snapshotAccumulator = 0

local function cellKey(cell: Cell): string
	return string.format("%d,%d", cell.x, cell.z)
end

local function sameCell(a: Cell, b: Cell): boolean
	return a.x == b.x and a.z == b.z
end

local function isInside(x: number, z: number): boolean
	return x >= 1 and x <= CONFIG.GridSize and z >= 1 and z <= CONFIG.GridSize
end

local function cellToWorld(cell: Cell, y: number?): Vector3
	local span = CONFIG.GridSize * CONFIG.CellSize
	return Vector3.new((cell.x - 0.5) * CONFIG.CellSize - span / 2, y or 1.5, (cell.z - 0.5) * CONFIG.CellSize - span / 2)
end

local function worldToCell(position: Vector3): Cell
	local span = CONFIG.GridSize * CONFIG.CellSize
	local x = math.floor((position.X + span / 2) / CONFIG.CellSize) + 1
	local z = math.floor((position.Z + span / 2) / CONFIG.CellSize) + 1
	return { x = math.clamp(x, 1, CONFIG.GridSize), z = math.clamp(z, 1, CONFIG.GridSize) }
end

local function createPart(
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	parent: Instance
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- visual parts never need to take part in physics or spatial queries
local function makePassive(part: BasePart)
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
end

local function addLight(parent: Instance, color: Color3, brightness: number, range: number)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = false
	light.Parent = parent
end

local function createPrompt(parent: BasePart, action: string, object: string, hold: number): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt.HoldDuration = hold
	prompt.MaxActivationDistance = CONFIG.PromptDistance
	prompt.Parent = parent
	return prompt
end

local function createFolder(name: string, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

local function fireMessage(player: Player, text: string, duration: number?)
	sentinelEvent:FireClient(player, { kind = "Message", text = text, duration = duration or 2.2 })
end

local function maximumAlert(): (number, string)
	local alert = 0
	local state = "PATROL"
	for _, drone in ipairs(drones) do
		if drone.Suspicion > alert then
			alert = drone.Suspicion
			state = string.upper(drone.State)
		end
	end
	return alert, state
end

local function pushSnapshot(player: Player)
	local state = playerStates[player]
	if not state then
		return
	end
	local alert, droneState = maximumAlert()
	sentinelEvent:FireClient(player, {
		kind = "Snapshot",
		collected = state.collected,
		required = CONFIG.RequiredCores,
		alert = alert,
		droneState = droneState,
		status = state.status,
		startedAt = state.startedAt,
		seed = currentSeed,
	})
end

local function newMaze(): Maze
	local maze: Maze = {}
	for x = 1, CONFIG.GridSize do
		maze[x] = {}
		for z = 1, CONFIG.GridSize do
			maze[x][z] = { North = true, East = true, South = true, West = true, Visited = false }
		end
	end
	return maze
end

local function carveMaze(seed: number): Maze
	local maze = newMaze()
	local random = Random.new(seed)
	local stack: { Cell } = { { x = 1, z = 1 } }
	maze[1][1].Visited = true
	-- this stack gives us recursive backtracking without growing the call stack
	while #stack > 0 do
		local current = stack[#stack]
		local candidates = {}
		for _, direction in ipairs(DirectionData) do
			local nx = current.x + direction.dx
			local nz = current.z + direction.dz
			if isInside(nx, nz) and not maze[nx][nz].Visited then
				table.insert(candidates, direction)
			end
		end
		if #candidates == 0 then
			table.remove(stack)
		else
			local direction = candidates[random:NextInteger(1, #candidates)]
			local nx = current.x + direction.dx
			local nz = current.z + direction.dz
			maze[current.x][current.z][direction.name] = false
			maze[nx][nz][direction.opposite] = false
			maze[nx][nz].Visited = true
			table.insert(stack, { x = nx, z = nz })
		end
	end
	-- a few extra openings stop the generated route from feeling like one long tunnel
	for x = 1, CONFIG.GridSize do
		for z = 1, CONFIG.GridSize do
			if x < CONFIG.GridSize and random:NextNumber() < CONFIG.ExtraLoopChance then
				maze[x][z].East = false
				maze[x + 1][z].West = false
			end
			if z < CONFIG.GridSize and random:NextNumber() < CONFIG.ExtraLoopChance then
				maze[x][z].South = false
				maze[x][z + 1].North = false
			end
		end
	end
	return maze
end

local function getOpenNeighbors(maze: Maze, cell: Cell): { Cell }
	local neighbors = {}
	local mazeCell = maze[cell.x][cell.z]
	for _, direction in ipairs(DirectionData) do
		if not mazeCell[direction.name] then
			local nx = cell.x + direction.dx
			local nz = cell.z + direction.dz
			if isInside(nx, nz) then
				table.insert(neighbors, { x = nx, z = nz })
			end
		end
	end
	return neighbors
end

local function breadthFirstDistances(maze: Maze, origin: Cell): { [string]: number }
	-- breadth first search gives an exact step distance because every edge costs one
	local distances = { [cellKey(origin)] = 0 }
	local queue: { Cell } = { origin }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		local currentDistance = distances[cellKey(current)]
		for _, neighbor in ipairs(getOpenNeighbors(maze, current)) do
			local key = cellKey(neighbor)
			if distances[key] == nil then
				distances[key] = currentDistance + 1
				table.insert(queue, neighbor)
			end
		end
	end
	return distances
end

local function chooseImportantCells(maze: Maze, seed: number): (Cell, { Cell }, { Cell })
	-- ranking by distance keeps objectives away from the starting room
	local distances = breadthFirstDistances(maze, startCell)
	local ranked = {}
	for x = 1, CONFIG.GridSize do
		for z = 1, CONFIG.GridSize do
			local cell = { x = x, z = z }
			table.insert(ranked, { cell = cell, distance = distances[cellKey(cell)] or -1 })
		end
	end
	table.sort(ranked, function(a, b)
		return a.distance > b.distance
	end)
	local chosenExit = ranked[1].cell
	local candidates = {}
	local minimumDistance = math.max(4, math.floor(ranked[1].distance * 0.42))
	for _, item in ipairs(ranked) do
		if item.distance >= minimumDistance and not sameCell(item.cell, chosenExit) then
			table.insert(candidates, item.cell)
		end
	end
	local random = Random.new(seed + 97)
	for index = #candidates, 2, -1 do
		local swapIndex = random:NextInteger(1, index)
		candidates[index], candidates[swapIndex] = candidates[swapIndex], candidates[index]
	end
	local chosenCores = {}
	for index = 1, math.min(CONFIG.RequiredCores, #candidates) do
		table.insert(chosenCores, candidates[index])
	end
	local chosenPatrols = {
		ranked[math.max(2, math.floor(#ranked * 0.25))].cell,
		ranked[math.max(3, math.floor(#ranked * 0.55))].cell,
		ranked[math.max(4, math.floor(#ranked * 0.8))].cell,
	}
	return chosenExit, chosenCores, chosenPatrols
end

local function heapPush(heap: { HeapEntry }, entry: HeapEntry)
	-- bubbling upward keeps the cheapest astar candidate at the root
	table.insert(heap, entry)
	local index = #heap
	while index > 1 do
		local parentIndex = math.floor(index / 2)
		if heap[parentIndex].priority <= entry.priority then
			break
		end
		heap[index] = heap[parentIndex]
		index = parentIndex
	end
	heap[index] = entry
end

local function heapPop(heap: { HeapEntry }): HeapEntry?
	-- replacing the root and sifting down avoids sorting the whole open set
	if #heap == 0 then
		return nil
	end
	local root = heap[1]
	local last = table.remove(heap)
	if #heap > 0 and last then
		local index = 1
		while true do
			local left = index * 2
			local right = left + 1
			if left > #heap then
				break
			end
			local smaller = left
			if right <= #heap and heap[right].priority < heap[left].priority then
				smaller = right
			end
			if heap[smaller].priority >= last.priority then
				break
			end
			heap[index] = heap[smaller]
			index = smaller
		end
		heap[index] = last
	end
	return root
end

local function findPath(maze: Maze, origin: Cell, goal: Cell): { Cell }
	-- astar combines travelled cost with manhattan distance to the goal
	if sameCell(origin, goal) then
		return { origin }
	end
	local openHeap: { HeapEntry } = {}
	local cameFrom: { [string]: Cell } = {}
	local gScore: { [string]: number } = { [cellKey(origin)] = 0 }
	local closed: { [string]: boolean } = {}
	heapPush(openHeap, { cell = origin, priority = 0 })
	while #openHeap > 0 do
		local entry = heapPop(openHeap)
		if not entry then
			break
		end
		local current = entry.cell
		local currentKey = cellKey(current)
		if not closed[currentKey] then
			if sameCell(current, goal) then
				local path = { current }
				while cameFrom[currentKey] do
					current = cameFrom[currentKey]
					currentKey = cellKey(current)
					table.insert(path, 1, current)
				end
				return path
			end
			closed[currentKey] = true
			for _, neighbor in ipairs(getOpenNeighbors(maze, current)) do
				local neighborKey = cellKey(neighbor)
				local tentative = (gScore[currentKey] or math.huge) + 1
				if tentative < (gScore[neighborKey] or math.huge) then
					cameFrom[neighborKey] = current
					gScore[neighborKey] = tentative
					local heuristic = math.abs(goal.x - neighbor.x) + math.abs(goal.z - neighbor.z)
					heapPush(openHeap, { cell = neighbor, priority = tentative + heuristic })
				end
			end
		end
	end
	return {}
end

local function clearWorld()
	for _, connection in ipairs(worldConnections) do
		connection:Disconnect()
	end
	table.clear(worldConnections)
	table.clear(drones)
	if worldFolder then
		worldFolder:Destroy()
	end
	worldFolder = nil
	exitDoor = nil
	exitPrompt = nil
	restartPrompt = nil
	exitOpened = false
end

local function createWall(name: string, size: Vector3, position: Vector3)
	local wall = createPart(name, size, CFrame.new(position), COLORS.Wall, Enum.Material.Metal, mapFolder :: Folder)
	wall.CastShadow = true
end

local function buildMazeGeometry(maze: Maze)
	local span = CONFIG.GridSize * CONFIG.CellSize
	local horizontalWall = Vector3.new(CONFIG.CellSize + CONFIG.WallThickness, CONFIG.WallHeight, CONFIG.WallThickness)
	local verticalWall = Vector3.new(CONFIG.WallThickness, CONFIG.WallHeight, CONFIG.CellSize + CONFIG.WallThickness)
	-- the small height offset keeps this surface from fighting with the baseplate
	local floor = createPart(
		"FacilityFloor",
		Vector3.new(span + 2, 1, span + 2),
		CFrame.new(0, -0.35, 0),
		COLORS.Floor,
		Enum.Material.SmoothPlastic,
		mapFolder :: Folder
	)
	floor.CastShadow = false
	-- nine low cost fixtures cover the maze without shadow heavy lights
	local fixtureColor = Color3.fromRGB(214, 211, 190)
	for _, x in ipairs({ -42, 0, 42 }) do
		for _, z in ipairs({ -42, 0, 42 }) do
			local fixture = createPart("CeilingLight", Vector3.new(7, 0.25, 1.4), CFrame.new(x, 10.8, z), fixtureColor, Enum.Material.Neon, mapFolder :: Folder)
			makePassive(fixture)
			addLight(fixture, Color3.fromRGB(255, 232, 190), 1.8, 34)
		end
	end
	for x = 1, CONFIG.GridSize do
		for z = 1, CONFIG.GridSize do
			local cell = { x = x, z = z }
			local center = cellToWorld(cell, CONFIG.WallHeight / 2)
			local mazeCell = maze[x][z]
			if mazeCell.North then
				createWall(string.format("Wall_N_%d_%d", x, z), horizontalWall, center + Vector3.new(0, 0, -CONFIG.CellSize / 2))
			end
			if mazeCell.West then
				createWall(string.format("Wall_W_%d_%d", x, z), verticalWall, center + Vector3.new(-CONFIG.CellSize / 2, 0, 0))
			end
			if x == CONFIG.GridSize and mazeCell.East then
				createWall(string.format("Wall_E_%d_%d", x, z), verticalWall, center + Vector3.new(CONFIG.CellSize / 2, 0, 0))
			end
			if z == CONFIG.GridSize and mazeCell.South then
				createWall(string.format("Wall_S_%d_%d", x, z), horizontalWall, center + Vector3.new(0, 0, CONFIG.CellSize / 2))
			end
		end
	end
	local spawn = workspace:FindFirstChildOfClass("SpawnLocation")
	if not spawn then
		spawn = Instance.new("SpawnLocation")
		spawn.Name = "SentinelSpawn"
		spawn.Parent = workspace
	end
	spawn.Size = Vector3.new(6, 0.4, 6)
	spawn.CFrame = CFrame.new(cellToWorld(startCell, 0.35))
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanTouch = false
	spawn.Neutral = true
	for _, child in ipairs(spawn:GetChildren()) do
		if child:IsA("Decal") or child:IsA("Texture") then
			child:Destroy()
		end
	end
end

local function validatePrompt(player: Player, target: BasePart): (PlayerState?, BasePart?)
	-- prompts are only hints from the client so the server checks state rate and distance
	local state = playerStates[player]
	local root = getCharacterRoot(player)
	if not state or not root or state.status ~= "Running" then
		return nil, nil
	end
	local now = time()
	if now - state.lastPromptAt < CONFIG.PromptCooldown then
		return nil, nil
	end
	if (root.Position - target.Position).Magnitude > CONFIG.PromptDistance + 2 then
		return nil, nil
	end
	state.lastPromptAt = now
	return state, root
end

local function unlockExit()
	if exitOpened or not exitDoor or not exitPrompt then
		return
	end
	exitOpened = true
	exitPrompt.Enabled = true
	exitDoor.Color = COLORS.Exit
	local openCFrame = exitDoor.CFrame * CFrame.new(0, exitDoor.Size.Y + 1, 0)
	local tweenInfo = TweenInfo.new(1.1, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	TweenService:Create(exitDoor, tweenInfo, { CFrame = openCFrame, Transparency = 0.28 }):Play()
	for player, state in pairs(playerStates) do
		if state.status == "Running" then
			fireMessage(player, "ALL CORES SECURED — EXIT UNLOCKED", 3)
		end
	end
end

local function createCore(index: number, cell: Cell)
	-- each core owns its prompt and disconnects with the rest of the generated world
	local position = cellToWorld(cell, 2.4)
	local rotation = CFrame.new(position) * CFrame.Angles(0, math.rad(45), 0)
	local core = createPart("EnergyCore" .. index, Vector3.new(2.4, 2.4, 2.4), rotation, COLORS.Core, Enum.Material.Neon, objectiveFolder :: Folder)
	core.Shape = Enum.PartType.Ball
	core.CanCollide = false
	core:SetAttribute("Collected", false)
	addLight(core, COLORS.Core, 2.5, 14)
	local prompt = createPrompt(core, "Secure Core", string.format("ENERGY CORE %d", index), 0.45)
	prompt.RequiresLineOfSight = true
	table.insert(worldConnections, prompt.Triggered:Connect(function(player)
		local state = validatePrompt(player, core)
		if not state or core:GetAttribute("Collected") then
			return
		end
		core:SetAttribute("Collected", true)
		prompt.Enabled = false
		state.collected += 1
		fireMessage(player, string.format("CORE SECURED  %d/%d", state.collected, CONFIG.RequiredCores))
		pushSnapshot(player)
		TweenService:Create(core, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Size = Vector3.new(0.1, 0.1, 0.1),
			Transparency = 1,
		}):Play()
		task.delay(0.4, function()
			if core.Parent then
				core:Destroy()
			end
		end)
		if state.collected >= CONFIG.RequiredCores then
			unlockExit()
		end
	end))
end

local function createExit()
	local center = cellToWorld(exitCell, 0)
	local terminalCFrame = CFrame.new(center + Vector3.new(0, 2, 3.8))
	local terminal = createPart("ExitTerminal", Vector3.new(3, 4, 2), terminalCFrame, COLORS.Locked, Enum.Material.Metal, objectiveFolder :: Folder)
	local screenCFrame = terminal.CFrame * CFrame.new(0, 0.35, -1.08)
	local screen = createPart("ExitScreen", Vector3.new(2.25, 1.4, 0.15), screenCFrame, COLORS.Locked, Enum.Material.Neon, objectiveFolder :: Folder)
	screen.CanCollide = false
	local gateCFrame = CFrame.new(center + Vector3.new(0, 4.5, -3.8))
	exitDoor = createPart("ExitGate", Vector3.new(8, 9, 0.8), gateCFrame, COLORS.Locked, Enum.Material.ForceField, objectiveFolder :: Folder)
	exitPrompt = createPrompt(terminal, "Extract", "FACILITY EXIT", 0.65)
	exitPrompt.RequiresLineOfSight = false
	exitPrompt.Enabled = false
	restartPrompt = createPrompt(screen, "Generate Next Grid", "SIMULATION COMPLETE", 1)
	restartPrompt.RequiresLineOfSight = false
	restartPrompt.Enabled = false
	table.insert(worldConnections, exitPrompt.Triggered:Connect(function(player)
		local state = validatePrompt(player, terminal)
		if not state or state.collected < CONFIG.RequiredCores then
			return
		end
		state.status = "Completed"
		exitPrompt.Enabled = false
		restartPrompt.Enabled = true
		local elapsed = workspace:GetServerTimeNow() - state.startedAt
		sentinelEvent:FireClient(player, {
			kind = "Finish",
			elapsed = elapsed,
			seed = currentSeed,
		})
		pushSnapshot(player)
	end))
	table.insert(worldConnections, restartPrompt.Triggered:Connect(function(player)
		local state = playerStates[player]
		local root = getCharacterRoot(player)
		if rebuilding or not state or state.status ~= "Completed" or not root then
			return
		end
		if (root.Position - screen.Position).Magnitude > CONFIG.PromptDistance + 2 then
			return
		end
		rebuilding = true
		task.defer(function()
			currentSeed += 1
			-- the attribute keeps regeneration deferred until this callback has returned
			local rebuild = script:GetAttribute("RebuildRequested") or 0
			script:SetAttribute("RebuildRequested", rebuild + 1)
		end)
	end))
end

local Drone = {}
Drone.__index = Drone

function Drone.new(index: number, spawnCell: Cell, patrolRoute: { Cell })
	-- every drone shares these methods while keeping its own route and suspicion
	local model = Instance.new("Model")
	model.Name = "SentinelDrone" .. index
	local spawnPosition = cellToWorld(spawnCell, 3.4)
	local body = createPart("Body", Vector3.new(3.4, 2.1, 3.4), CFrame.new(spawnPosition), COLORS.Drone, Enum.Material.Metal, model)
	body.Shape = Enum.PartType.Ball
	makePassive(body)
	local eye = createPart("Eye", Vector3.new(1.4, 0.65, 0.45), body.CFrame * CFrame.new(0, 0.15, -1.55), Color3.fromRGB(255, 120, 120), Enum.Material.Neon, model)
	makePassive(eye)
	local vision = createPart("VisionIndicator", Vector3.new(2.8, 0.08, 6), body.CFrame * CFrame.new(0, -0.75, -4.3), COLORS.Drone, Enum.Material.Neon, model)
	vision.Transparency = 0.7
	makePassive(vision)
	model.PrimaryPart = body
	model.Parent = droneFolder
	model:PivotTo(CFrame.lookAt(spawnPosition, spawnPosition + Vector3.new(0, 0, -1)))
	local self = setmetatable({
		Index = index,
		Model = model,
		State = "Patrol",
		Suspicion = 0,
		PatrolRoute = patrolRoute,
		PatrolIndex = 1,
		Path = {} :: { Cell },
		PathIndex = 1,
		GoalCell = spawnCell,
		LastPathAt = -math.huge,
		LastKnownPosition = spawnPosition,
		LostSightAt = 0,
		SearchUntil = 0,
	}, Drone)
	return self
end

function Drone:setState(nextState: string)
	if self.State == nextState then
		return
	end
	self.State = nextState
	if nextState == "Search" then
		self.SearchUntil = time() + CONFIG.SearchDuration
	elseif nextState == "Return" then
		self.Suspicion = math.min(self.Suspicion, 0.2)
	end
end

function Drone:canSee(player: Player): (boolean, BasePart?)
	-- the dot product checks the view cone before the raycast checks solid cover
	local state = playerStates[player]
	local root = getCharacterRoot(player)
	if not state or not root or state.status ~= "Running" or time() < state.invulnerableUntil then
		return false, root
	end
	local origin = self.Model:GetPivot().Position + Vector3.new(0, 0.25, 0)
	local offset = root.Position - origin
	local distance = offset.Magnitude
	if distance <= 0.01 or distance > CONFIG.VisionRange then
		return false, root
	end
	local facing = self.Model:GetPivot().LookVector
	if facing:Dot(offset.Unit) < math.cos(CONFIG.VisionHalfAngle) then
		return false, root
	end
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { droneFolder :: Folder, objectiveFolder :: Folder, effectFolder :: Folder }
	parameters.IgnoreWater = true
	local result = workspace:Raycast(origin, offset, parameters)
	return result ~= nil and result.Instance:IsDescendantOf(player.Character :: Model), root
end

function Drone:refreshPath(goal: Cell, force: boolean?)
	local now = time()
	if not force and sameCell(goal, self.GoalCell) and now - self.LastPathAt < CONFIG.PathRefresh then
		return
	end
	self.GoalCell = goal
	self.LastPathAt = now
	local maze = currentMaze
	if not maze then
		self.Path = {}
		return
	end
	local origin = worldToCell(self.Model:GetPivot().Position)
	self.Path = findPath(maze, origin, goal)
	self.PathIndex = #self.Path > 1 and 2 or 1
end

function Drone:moveAlongPath(dt: number): boolean
	local waypoint = self.Path[self.PathIndex]
	if not waypoint then
		return true
	end
	local currentPivot = self.Model:GetPivot()
	local currentPosition = currentPivot.Position
	local targetPosition = cellToWorld(waypoint, 3.4)
	local offset = targetPosition - currentPosition
	local distance = offset.Magnitude
	if distance < 0.35 then
		self.PathIndex += 1
		return self.Path[self.PathIndex] == nil
	end
	local step = math.min(distance, CONFIG.DroneSpeed * dt)
	local direction = offset.Unit
	local nextPosition = currentPosition + direction * step
	self.Model:PivotTo(CFrame.lookAt(nextPosition, nextPosition + direction))
	return false
end

local function createShockwave(position: Vector3)
	local wave = createPart("CaptureWave", Vector3.one, CFrame.new(position), COLORS.Drone, Enum.Material.Neon, effectFolder :: Folder)
	wave.Shape = Enum.PartType.Ball
	makePassive(wave)
	wave.Transparency = 0.2
	TweenService:Create(wave, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Size = Vector3.new(18, 18, 18),
		Transparency = 1,
	}):Play()
	Debris:AddItem(wave, 0.45)
end

local function capturePlayer(player: Player, dronePosition: Vector3)
	-- capture is server owned so a client cannot choose when or where recovery happens
	local state = playerStates[player]
	local root = getCharacterRoot(player)
	if not state or not root or state.status ~= "Running" or state.capturing then
		return
	end
	if time() < state.invulnerableUntil then
		return
	end
	state.capturing = true
	state.invulnerableUntil = time() + CONFIG.CaptureRecovery + CONFIG.CaptureProtection
	createShockwave(root.Position)
	local away = root.Position - dronePosition
	if away.Magnitude < 0.1 then
		away = Vector3.new(0, 0, -1)
	end
	-- scaling by assembly mass keeps knockback consistent across avatar packages
	root:ApplyImpulse((away.Unit * 38 + Vector3.new(0, 23, 0)) * root.AssemblyMass)
	sentinelEvent:FireClient(player, { kind = "Pulse", intensity = 1 })
	fireMessage(player, "SIGNAL COMPROMISED — REBOOTING", 1.6)
	task.delay(CONFIG.CaptureRecovery, function()
		local refreshedRoot = getCharacterRoot(player)
		if refreshedRoot and playerStates[player] == state then
			refreshedRoot.CFrame = CFrame.new(cellToWorld(startCell, 3.5))
			refreshedRoot.AssemblyLinearVelocity = Vector3.zero
			refreshedRoot.AssemblyAngularVelocity = Vector3.zero
		end
		state.capturing = false
		for _, drone in ipairs(drones) do
			drone.Suspicion = 0
			drone:setState("Return")
		end
		pushSnapshot(player)
	end)
end

function Drone:update(dt: number, player: Player?)
	-- sensing updates suspicion first and the state machine decides movement second
	if not player then
		return
	end
	local playerState = playerStates[player]
	local visible, root = self:canSee(player)
	local heard = false
	if root and playerState and playerState.status == "Running" then
		local distance = (root.Position - self.Model:GetPivot().Position).Magnitude
		local velocity = root.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
		heard = distance <= CONFIG.HearingRange and velocity.Magnitude >= CONFIG.HearingSpeed
	end
	if visible and root then
		self.LastKnownPosition = root.Position
		self.LostSightAt = 0
		self.Suspicion = math.clamp(self.Suspicion + CONFIG.SuspicionGain * dt, 0, 1)
	elseif heard and root then
		self.LastKnownPosition = root.Position
		self.Suspicion = math.clamp(self.Suspicion + CONFIG.HearingGain * dt, 0, 1)
	elseif self.State ~= "Chase" then
		self.Suspicion = math.clamp(self.Suspicion - CONFIG.SuspicionDecay * dt, 0, 1)
	end
	if self.Suspicion >= 1 and self.State ~= "Chase" then
		self:setState("Chase")
		fireMessage(player, "DETECTED — BREAK LINE OF SIGHT", 2.4)
	elseif self.State == "Patrol" and self.Suspicion >= 0.24 then
		self:setState("Investigate")
	end
	if not playerState or playerState.status ~= "Running" then
		self:setState("Return")
	end
	if self.State == "Patrol" then
		local goal = self.PatrolRoute[self.PatrolIndex]
		self:refreshPath(goal)
		if self:moveAlongPath(dt) then
			self.PatrolIndex = (self.PatrolIndex % #self.PatrolRoute) + 1
			self:refreshPath(self.PatrolRoute[self.PatrolIndex], true)
		end
	elseif self.State == "Investigate" then
		self:refreshPath(worldToCell(self.LastKnownPosition))
		if self:moveAlongPath(dt) and self.Suspicion < 0.1 then
			self:setState("Return")
		end
	elseif self.State == "Chase" then
		if visible and root then
			self:refreshPath(worldToCell(root.Position))
		elseif self.LostSightAt == 0 then
			self.LostSightAt = time()
		elseif time() - self.LostSightAt >= 1 then
			self:setState("Search")
		end
		self:moveAlongPath(dt)
		if root and (root.Position - self.Model:GetPivot().Position).Magnitude <= CONFIG.CaptureDistance then
			capturePlayer(player, self.Model:GetPivot().Position)
		end
	elseif self.State == "Search" then
		self:refreshPath(worldToCell(self.LastKnownPosition))
		self:moveAlongPath(dt)
		self.Suspicion = math.clamp(self.Suspicion - CONFIG.SuspicionDecay * 0.45 * dt, 0, 1)
		if time() >= self.SearchUntil then
			self:setState("Return")
		end
	elseif self.State == "Return" then
		local goal = self.PatrolRoute[self.PatrolIndex]
		self:refreshPath(goal)
		if self:moveAlongPath(dt) then
			self:setState("Patrol")
		end
	end
end

local function teleportPlayerToStart(player: Player)
	local root = getCharacterRoot(player)
	if root then
		root.CFrame = CFrame.new(cellToWorld(startCell, 3.5))
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

local function resetPlayerState(player: Player)
	playerStates[player] = {
		collected = 0,
		status = "Running",
		startedAt = workspace:GetServerTimeNow(),
		lastPromptAt = -math.huge,
		invulnerableUntil = time() + 1.5,
		capturing = false,
	}
	task.defer(function()
		teleportPlayerToStart(player)
		pushSnapshot(player)
		fireMessage(player, "SECURE 3 CORES, EVADE SENTINELS, REACH THE EXIT", 4)
	end)
end

local function buildWorld(seed: number)
	-- the seed rebuilds geometry objectives and patrol routes as one owned lifetime
	clearWorld()
	currentSeed = seed
	currentMaze = carveMaze(seed)
	exitCell, coreCells, patrolCells = chooseImportantCells(currentMaze, seed)
	worldFolder = Instance.new("Folder")
	worldFolder.Name = "SentinelGrid"
	mapFolder = createFolder("Map", worldFolder)
	objectiveFolder = createFolder("Objectives", worldFolder)
	droneFolder = createFolder("Drones", worldFolder)
	effectFolder = createFolder("Effects", worldFolder)
	worldFolder.Parent = workspace
	buildMazeGeometry(currentMaze)
	for index, cell in ipairs(coreCells) do
		createCore(index, cell)
	end
	createExit()
	for index = 1, CONFIG.DroneCount do
		local spawn = patrolCells[((index - 1) % #patrolCells) + 1]
		local route = {
			patrolCells[((index - 1) % #patrolCells) + 1],
			patrolCells[(index % #patrolCells) + 1],
			patrolCells[((index + 1) % #patrolCells) + 1],
		}
		table.insert(drones, Drone.new(index, spawn, route))
	end
	for player in pairs(playerStates) do
		resetPlayerState(player)
	end
	rebuilding = false
end

script:GetAttributeChangedSignal("RebuildRequested"):Connect(function()
	if rebuilding then
		buildWorld(currentSeed)
	end
end)

Lighting.ClockTime = 20
Lighting.Brightness = 3
Lighting.Ambient = Color3.fromRGB(128, 122, 105)
Lighting.OutdoorAmbient = Color3.fromRGB(92, 91, 79)
Lighting.ExposureCompensation = 0.45
buildWorld(currentSeed)

local function onPlayerAdded(player: Player)
	resetPlayerState(player)
	player.CharacterAdded:Connect(function()
		task.wait()
		teleportPlayerToStart(player)
		pushSnapshot(player)
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	playerStates[player] = nil
end)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

RunService.Heartbeat:Connect(function(rawDt)
	local dt = math.min(rawDt, 1 / 15)
	local player = Players:GetPlayers()[1]
	for _, drone in ipairs(drones) do
		drone:update(dt, player)
	end
	snapshotAccumulator += dt
	if snapshotAccumulator >= CONFIG.SnapshotRate then
		snapshotAccumulator = 0
		if player then
			pushSnapshot(player)
		end
	end
end)
