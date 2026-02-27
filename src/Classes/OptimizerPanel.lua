-- Path of Building
--
-- Class: Optimizer Panel
-- UI panel for the passive tree auto-optimizer.
--

local t_insert = table.insert
local t_remove = table.remove
local m_floor = math.floor
local m_max = math.max
local s_format = string.format

local OptimizerPanelClass = newClass("OptimizerPanel", "Control", "ControlHost", function(self, anchor, rect, build)
	self.Control(anchor, rect)
	self.ControlHost()
	self.build = build
	self.optimizer = build.calcsTab.calcs.optimizer
	self.pinnedNodes = { }           -- { [nodeId] = true }
	self.pinnedNodesList = { }       -- array of { id, name, type } for display
	self.pinMode = false
	self.running = false
	self.optimizerCoroutine = nil
	self.bestResult = nil
	self.originalAlloc = nil         -- snapshot before optimization
	self.alpha = 0.5                 -- offence/defence balance
	self.pointBudget = 0
	self.progressPct = 0

	local width = rect[3]

	-- Offence/Defence priority slider
	self.controls.alphaLabel = new("LabelControl", { "TOPLEFT", self, "TOPLEFT" }, { 10, 8, 0, 16 }, "Defence")
	self.controls.alphaSlider = new("SliderControl", { "LEFT", self.controls.alphaLabel, "RIGHT" }, { 8, 0, 150, 16 }, function(val)
		self.alpha = val
	end)
	self.controls.alphaSlider:SetVal(0.5)
	self.controls.alphaLabelR = new("LabelControl", { "LEFT", self.controls.alphaSlider, "RIGHT" }, { 8, 0, 0, 16 }, "Offence")

	-- Point budget
	self.controls.budgetLabel = new("LabelControl", { "LEFT", self.controls.alphaLabelR, "RIGHT" }, { 20, 0, 0, 16 }, "Points:")
	self.controls.budgetEdit = new("EditControl", { "LEFT", self.controls.budgetLabel, "RIGHT" }, { 4, 0, 50, 18 }, "", nil, "%D", 3, function(buf)
		self.pointBudget = tonumber(buf) or 0
	end)

	-- Pin mode toggle
	self.controls.pinModeBtn = new("ButtonControl", { "LEFT", self.controls.budgetEdit, "RIGHT" }, { 12, 0, 100, 18 },
		function() return self.pinMode and "Pin Mode: ON" or "Pin Mode: OFF" end,
		function()
			self.pinMode = not self.pinMode
		end)

	-- Start/Stop button
	self.controls.startBtn = new("ButtonControl", { "LEFT", self.controls.pinModeBtn, "RIGHT" }, { 12, 0, 80, 18 },
		function() return self.running and "Stop" or "Start" end,
		function()
			if self.running then
				self:StopOptimizer()
			else
				self:StartOptimizer()
			end
		end)

	-- Progress label
	self.controls.progressLabel = new("LabelControl", { "LEFT", self.controls.startBtn, "RIGHT" }, { 12, 0, 0, 16 }, "")

	-- Second row: Pinned nodes search
	self.controls.pinSearchLabel = new("LabelControl", { "TOPLEFT", self, "TOPLEFT" }, { 10, 32, 0, 16 }, "Pin Node:")
	self.controls.pinSearch = new("EditControl", { "LEFT", self.controls.pinSearchLabel, "RIGHT" }, { 4, 0, 200, 18 }, "", "Search...", nil, nil, function(buf)
		self:UpdateSearchResults(buf)
	end)
	self.controls.pinSearchResults = new("DropDownControl", { "LEFT", self.controls.pinSearch, "RIGHT" }, { 4, 0, 200, 18 }, { }, function(index, value)
		if value and value.id then
			self:PinNode(value.id, value.name, value.type)
			self.controls.pinSearch:SetText("")
		end
	end)

	-- Pinned nodes count label
	self.controls.pinnedLabel = new("LabelControl", { "LEFT", self.controls.pinSearchResults, "RIGHT" }, { 12, 0, 0, 16 },
		function() return "Pinned: " .. #self.pinnedNodesList end)

	-- Apply / Reset buttons (row 3, shown after optimization)
	self.controls.applyBtn = new("ButtonControl", { "TOPLEFT", self, "TOPLEFT" }, { 10, 56, 120, 18 }, "Apply Best Tree", function()
		self:ApplyBestTree()
	end)
	self.controls.applyBtn.shown = function() return self.bestResult ~= nil end

	self.controls.resetBtn = new("ButtonControl", { "LEFT", self.controls.applyBtn, "RIGHT" }, { 8, 0, 120, 18 }, "Reset to Original", function()
		self:ResetToOriginal()
	end)
	self.controls.resetBtn.shown = function() return self.originalAlloc ~= nil end

	-- Default budget from build level
	self:UpdateBudgetFromLevel()
end)

function OptimizerPanelClass:UpdateBudgetFromLevel()
	local level = self.build.characterLevel or 1
	local points = m_max(0, level - 1)
	self.pointBudget = points
	self.controls.budgetEdit:SetText(tostring(points))
end

function OptimizerPanelClass:PinNode(id, name, nodeType)
	if self.pinnedNodes[id] then return end
	if #self.pinnedNodesList >= 5 then return end
	self.pinnedNodes[id] = true
	t_insert(self.pinnedNodesList, { id = id, name = name, type = nodeType })
end

function OptimizerPanelClass:UnpinNode(id)
	self.pinnedNodes[id] = nil
	for i = #self.pinnedNodesList, 1, -1 do
		if self.pinnedNodesList[i].id == id then
			t_remove(self.pinnedNodesList, i)
			break
		end
	end
end

function OptimizerPanelClass:UpdateSearchResults(query)
	local results = self.optimizer.findNodesByName(self.build.spec, query)
	local dropList = { }
	for i = 1, math.min(#results, 10) do
		t_insert(dropList, {
			label = results[i].name .. " (" .. results[i].type .. ")",
			id = results[i].id,
			name = results[i].name,
			type = results[i].type,
		})
	end
	self.controls.pinSearchResults:SetList(dropList)
end

function OptimizerPanelClass:StartOptimizer()
	if self.running then return end
	self.originalAlloc = self.optimizer.snapshotAlloc(self.build.spec)
	self.bestResult = nil
	self.running = true
	self.progressPct = 0
	self.controls.progressLabel.label = "Starting..."

	self.optimizerCoroutine = self.optimizer.createOptimizerCoroutine(self.build, {
		alpha = self.alpha,
		maxIterations = 10000,
		pointBudget = self.pointBudget,
		pinnedNodes = self.pinnedNodes,
		customWeights = nil,
	})
end

function OptimizerPanelClass:StopOptimizer()
	self.running = false
	self.optimizerCoroutine = nil
	if self.originalAlloc then
		self.optimizer.restoreAlloc(self.build.spec, self.originalAlloc)
		self.build.buildFlag = true
	end
	self.controls.progressLabel.label = "Stopped"
end

function OptimizerPanelClass:ResumeOptimizer()
	if not self.running or not self.optimizerCoroutine then return end

	local status = coroutine.status(self.optimizerCoroutine)
	if status == "dead" then
		self.running = false
		self.optimizerCoroutine = nil
		return
	end

	local ok, val = coroutine.resume(self.optimizerCoroutine)
	if not ok then
		self.running = false
		self.optimizerCoroutine = nil
		self.controls.progressLabel.label = "Error: " .. tostring(val)
		return
	end

	if coroutine.status(self.optimizerCoroutine) == "dead" then
		self.bestResult = val
		self.running = false
		self.optimizerCoroutine = nil
		self.controls.progressLabel.label = s_format("Done! Best score: %.2f (%d iterations)", val.bestScore, val.iterations)
		self:ApplyBestTree()
	elseif val then
		self.progressPct = val.progress or 0
		self.controls.progressLabel.label = s_format("Optimizing... %d%% (best: %.2f)", m_floor(self.progressPct * 100), val.bestScore)
	end
end

function OptimizerPanelClass:ApplyBestTree()
	if not self.bestResult then return end
	self.optimizer.restoreAlloc(self.build.spec, self.bestResult.bestAlloc)
	self.build.buildFlag = true
end

function OptimizerPanelClass:ResetToOriginal()
	if not self.originalAlloc then return end
	self.optimizer.restoreAlloc(self.build.spec, self.originalAlloc)
	self.bestResult = nil
	self.build.buildFlag = true
	self.controls.progressLabel.label = ""
end

function OptimizerPanelClass:OnFrame()
	if self.running then
		self:ResumeOptimizer()
	end
end

function OptimizerPanelClass:HandleNodeClick(node)
	if not self.pinMode then return false end
	if node.type == "ClassStart" or node.type == "AscendClassStart" then return false end
	if self.pinnedNodes[node.id] then
		self:UnpinNode(node.id)
	else
		self:PinNode(node.id, node.dn, node.type)
	end
	return true
end

function OptimizerPanelClass:Draw(viewPort)
	if not self.shown then return end

	local x, y = self:GetPos()
	local width, height = self:GetSize()

	-- Background
	SetDrawColor(0.05, 0.05, 0.1, 0.95)
	DrawImage(nil, x, y, width, height)
	SetDrawColor(0.5, 0.5, 0.6, 1)
	DrawImage(nil, x, y, width, 1)

	-- Draw pinned nodes as text below controls
	local pinY = y + 78
	SetDrawColor(1, 1, 1, 1)
	for i, pin in ipairs(self.pinnedNodesList) do
		DrawString(x + 10, pinY + (i - 1) * 16, "LEFT", 14, "VAR", pin.name .. " [" .. pin.type .. "]")
	end

	self:DrawControls(viewPort)
end
