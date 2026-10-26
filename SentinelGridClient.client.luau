-- Connected Discord-GitHub
--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local sentinelEvent = ReplicatedStorage:WaitForChild("SentinelEvent") :: RemoteEvent

local existing = player:WaitForChild("PlayerGui"):FindFirstChild("SentinelHUD")
if existing then
	existing:Destroy()
end

local INK = Color3.fromRGB(224, 224, 211)
local MUTED = Color3.fromRGB(132, 137, 128)
local FAINT = Color3.fromRGB(59, 64, 59)
local PAPER = Color3.fromRGB(12, 14, 13)
local AMBER = Color3.fromRGB(229, 166, 63)
local DANGER = Color3.fromRGB(224, 69, 62)

local gui = Instance.new("ScreenGui")
gui.Name = "SentinelHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 20
gui.Parent = player.PlayerGui

local function makeFrame(parent: Instance, name: string, size: UDim2, position: UDim2, color: Color3, transparency: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BorderSizePixel = 0
	frame.Size = size
	frame.Position = position
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.Parent = parent
	return frame
end

local function makeLabel(parent: Instance, name: string, text: string, size: UDim2, position: UDim2, textSize: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = position
	label.Font = Enum.Font.Code
	label.Text = text
	label.TextColor3 = INK
	label.TextSize = textSize
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = parent
	return label
end

local panel = makeFrame(gui, "StatusPanel", UDim2.fromOffset(308, 188), UDim2.fromOffset(32, 30), PAPER, 1)

makeFrame(panel, "IndexMark", UDim2.fromOffset(4, 16), UDim2.fromOffset(0, 2), AMBER, 0)
local title = makeLabel(panel, "Title", "SENTINEL / GRID", UDim2.fromOffset(260, 20), UDim2.fromOffset(16, 0), 14)
title.Font = Enum.Font.GothamBold

local sectorLabel = makeLabel(panel, "SectorLabel", "ACTIVE SECTOR", UDim2.fromOffset(130, 18), UDim2.fromOffset(0, 34), 11)
sectorLabel.TextColor3 = MUTED

local objectiveLabel = makeLabel(panel, "Objective", "0 / 3", UDim2.fromOffset(176, 52), UDim2.fromOffset(-2, 50), 40)
objectiveLabel.Font = Enum.Font.GothamBold

local coresLabel = makeLabel(panel, "CoresLabel", "CORES SECURED", UDim2.fromOffset(132, 18), UDim2.fromOffset(176, 76), 11)
coresLabel.TextColor3 = MUTED

makeFrame(panel, "Divider", UDim2.fromOffset(280, 1), UDim2.fromOffset(0, 112), FAINT, 0)

local statePrefix = makeLabel(panel, "StatePrefix", "THREAT", UDim2.fromOffset(62, 18), UDim2.fromOffset(0, 124), 11)
statePrefix.TextColor3 = MUTED
local stateLabel = makeLabel(panel, "State", "PATROL", UDim2.fromOffset(130, 18), UDim2.fromOffset(68, 124), 12)

local timerLabel = makeLabel(panel, "Timer", "00:00.00", UDim2.fromOffset(92, 18), UDim2.fromOffset(188, 124), 12)
timerLabel.TextXAlignment = Enum.TextXAlignment.Right

local alertTrack = makeFrame(panel, "AlertTrack", UDim2.fromOffset(280, 2), UDim2.fromOffset(0, 158), FAINT, 0)
local alertFill = makeFrame(alertTrack, "AlertFill", UDim2.fromScale(0, 1), UDim2.fromOffset(0, 0), MUTED, 0)

local alertLabel = makeLabel(panel, "AlertLabel", "SIGNAL 00", UDim2.fromOffset(130, 18), UDim2.fromOffset(0, 166), 10)
alertLabel.TextColor3 = MUTED

local seedLabel = makeLabel(gui, "Seed", "314159 / SEED", UDim2.fromOffset(180, 22), UDim2.new(1, -212, 0, 30), 11)
seedLabel.TextXAlignment = Enum.TextXAlignment.Right
seedLabel.TextColor3 = MUTED

local messagePanel = makeFrame(gui, "MessagePanel", UDim2.fromOffset(520, 44), UDim2.new(0, 32, 1, -32), PAPER, 0.08)
messagePanel.AnchorPoint = Vector2.new(0, 1)
messagePanel.Visible = false
makeFrame(messagePanel, "MessageMark", UDim2.fromOffset(24, 3), UDim2.fromOffset(16, 0), AMBER, 0)
local messageLabel = makeLabel(messagePanel, "Message", "", UDim2.new(1, -32, 1, -4), UDim2.fromOffset(16, 4), 13)
messageLabel.TextTransparency = 1

local finishPanel = Instance.new("CanvasGroup")
finishPanel.Name = "FinishPanel"
finishPanel.AnchorPoint = Vector2.new(1, 0.5)
finishPanel.Position = UDim2.new(1, -36, 0.5, 0)
finishPanel.Size = UDim2.fromOffset(392, 224)
finishPanel.BorderSizePixel = 0
finishPanel.BackgroundColor3 = PAPER
finishPanel.BackgroundTransparency = 0.04
finishPanel.GroupTransparency = 1
finishPanel.Visible = false
finishPanel.Parent = gui

makeFrame(finishPanel, "FinishRule", UDim2.fromOffset(64, 4), UDim2.fromOffset(28, 0), AMBER, 0)
local finishKicker = makeLabel(finishPanel, "FinishKicker", "RUN / COMPLETE", UDim2.new(1, -52, 0, 22), UDim2.fromOffset(28, 22), 11)
finishKicker.TextColor3 = AMBER
local finishTitle = makeLabel(finishPanel, "FinishTitle", "GRID CLEARED", UDim2.new(1, -52, 0, 42), UDim2.fromOffset(26, 48), 28)
finishTitle.Font = Enum.Font.GothamBold
local finishTime = makeLabel(finishPanel, "FinishTime", "00:00.00", UDim2.new(1, -52, 0, 48), UDim2.fromOffset(26, 94), 32)
finishTime.Font = Enum.Font.GothamBold
local finishSeed = makeLabel(finishPanel, "FinishSeed", "SEED 000000", UDim2.new(1, -52, 0, 20), UDim2.fromOffset(28, 144), 11)
finishSeed.TextColor3 = MUTED
makeFrame(finishPanel, "FinishDivider", UDim2.new(1, -56, 0, 1), UDim2.fromOffset(28, 172), FAINT, 0)
local finishHint = makeLabel(finishPanel, "FinishHint", "Use the exit terminal to build the next grid", UDim2.new(1, -52, 0, 34), UDim2.fromOffset(28, 180), 12)
finishHint.TextColor3 = MUTED
finishHint.TextWrapped = true

local pulse = makeFrame(gui, "CapturePulse", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 0), DANGER, 1)
pulse.ZIndex = 50

local targetAlert = 0
local displayedAlert = 0
local runStatus = "Waiting"
local startedAt = workspace:GetServerTimeNow()
local frozenElapsed = 0
local messageToken = 0

local function formatTime(seconds: number): string
	seconds = math.max(0, seconds)
	local minutes = math.floor(seconds / 60)
	local remainder = seconds - minutes * 60
	return string.format("%02d:%05.2f", minutes, remainder)
end

local function showMessage(text: string, duration: number)
	messageToken += 1
	local token = messageToken
	messagePanel.Visible = true
	messageLabel.Text = string.upper(text)
	TweenService:Create(messageLabel, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 0,
	}):Play()
	task.delay(duration, function()
		if token == messageToken then
			local fade = TweenService:Create(messageLabel, TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				TextTransparency = 1,
			})
			fade:Play()
			fade.Completed:Once(function()
				if token == messageToken then
					messagePanel.Visible = false
				end
			end)
		end
	end)
end

local function playCapturePulse()
	pulse.BackgroundTransparency = 1
	local appear = TweenService:Create(pulse, TweenInfo.new(0.08), { BackgroundTransparency = 0.56 })
	local fade = TweenService:Create(pulse, TweenInfo.new(0.36, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	})
	appear:Play()
	appear.Completed:Once(function()
		fade:Play()
	end)
end

sentinelEvent.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" or type(payload.kind) ~= "string" then
		return
	end
	if payload.kind == "Snapshot" then
		objectiveLabel.Text = string.format("%d / %d", payload.collected or 0, payload.required or 3)
		targetAlert = math.clamp(tonumber(payload.alert) or 0, 0, 1)
		stateLabel.Text = string.upper(tostring(payload.droneState or "PATROL"))
		runStatus = tostring(payload.status or "Waiting")
		startedAt = tonumber(payload.startedAt) or workspace:GetServerTimeNow()
		seedLabel.Text = string.format("%d / SEED", tonumber(payload.seed) or 0)
		if runStatus == "Running" then
			finishPanel.Visible = false
		end
	elseif payload.kind == "Message" then
		showMessage(tostring(payload.text or ""), tonumber(payload.duration) or 2)
	elseif payload.kind == "Pulse" then
		playCapturePulse()
	elseif payload.kind == "Finish" then
		frozenElapsed = tonumber(payload.elapsed) or 0
		finishTime.Text = formatTime(frozenElapsed)
		finishSeed.Text = string.format("SEED %d", tonumber(payload.seed) or 0)
		finishPanel.GroupTransparency = 1
		finishPanel.Visible = true
		TweenService:Create(finishPanel, TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			GroupTransparency = 0,
		}):Play()
	end
end)

RunService.RenderStepped:Connect(function(dt)
	displayedAlert += (targetAlert - displayedAlert) * math.min(1, dt * 10)
	alertFill.Size = UDim2.fromScale(displayedAlert, 1)
	alertFill.BackgroundColor3 = MUTED:Lerp(DANGER, displayedAlert)
	alertLabel.Text = string.format("SIGNAL %02d", math.floor(displayedAlert * 99 + 0.5))
	stateLabel.TextColor3 = if displayedAlert > 0.58 then DANGER else INK
	if runStatus == "Running" then
		timerLabel.Text = formatTime(workspace:GetServerTimeNow() - startedAt)
	elseif runStatus == "Completed" then
		timerLabel.Text = formatTime(frozenElapsed)
	end
end)
