-- Path of Building
--
-- Module: Tree Optimizer
-- Simulated Annealing passive tree optimizer.
--
local m_max = math.max
local m_exp = math.exp
local m_floor = math.floor
local m_random = math.random
local t_insert = table.insert
local t_remove = table.remove

local optimizer = { }

-- Default defence stat weights
optimizer.defaultDefenceWeights = {
	Life = 1.0,
	EnergyShield = 1.0,
	Armour = 1.0,
	Evasion = 1.0,
	LifeRegen = 1.0,
	ESRegen = 1.0,
}

-- Compute raw defence metric from output, using weights
function optimizer.calcDefenceMetric(output, weights)
	local w = weights or optimizer.defaultDefenceWeights
	return (w.Life or 0) * (output.LifeUnreserved or 0) / 3000
		+ (w.EnergyShield or 0) * (output.EnergyShieldRecoveryCap or output.EnergyShield or 0) / 3000
		+ (w.Armour or 0) * (output.Armour or 0) / 10000
		+ (w.Evasion or 0) * (output.Evasion or 0) / 10000
		+ (w.LifeRegen or 0) * (output.LifeRegenRecovery or 0) / 500
		+ (w.ESRegen or 0) * (output.EnergyShieldRegenRecovery or 0) / 1000
end

-- Calculate weighted score combining offence and defence.
-- alpha: 0.0 = pure defence, 1.0 = pure offence.
-- customWeights: optional table overriding defence stat weights.
function optimizer.calcScore(output, baseOutput, alpha, customWeights)
	-- Offence: ratio of CombinedDPS to base
	local baseDPS = m_max(1, baseOutput.CombinedDPS or 0)
	local offenceRatio = (output.CombinedDPS or 0) / baseDPS

	-- Defence: ratio of defence metric to base
	local baseDefence = m_max(0.001, optimizer.calcDefenceMetric(baseOutput, customWeights))
	local defenceRatio = optimizer.calcDefenceMetric(output, customWeights) / baseDefence

	return alpha * offenceRatio + (1 - alpha) * defenceRatio
end

-- Get all unallocated nodes exactly 1 hop from the current tree.
-- These are candidates for the Add mutation.
function optimizer.getReachableNodes(spec)
	local reachable = { }
	for id, node in pairs(spec.nodes) do
		if not node.alloc
			and node.type ~= "ClassStart"
			and node.type ~= "AscendClassStart"
			and node.type ~= "Mastery"
			and node.pathDist == 1 then
			t_insert(reachable, node)
		end
	end
	return reachable
end

-- Get all allocated leaf nodes (nodes whose removal won't disconnect the tree).
-- A node is a leaf if no other allocated node depends solely on it.
-- Pinned nodes and class starts are excluded.
function optimizer.getLeafNodes(spec, pinnedNodes)
	local leaves = { }
	for id, node in pairs(spec.allocNodes) do
		if node.type ~= "ClassStart"
			and node.type ~= "AscendClassStart"
			and not pinnedNodes[id]
			and node.depends
			and #node.depends == 1      -- only depends on itself
		then
			t_insert(leaves, node)
		end
	end
	return leaves
end

-- Snapshot current allocation as a set of node IDs.
function optimizer.snapshotAlloc(spec)
	local snapshot = { }
	for id in pairs(spec.allocNodes) do
		snapshot[id] = true
	end
	return snapshot
end

-- Restore allocation from a snapshot.
function optimizer.restoreAlloc(spec, snapshot)
	-- Clear all allocations
	for id, node in pairs(spec.allocNodes) do
		node.alloc = false
	end
	wipeTable(spec.allocNodes)

	-- Restore from snapshot
	for id in pairs(snapshot) do
		local node = spec.nodes[id]
		if node then
			node.alloc = true
			spec.allocNodes[id] = node
		end
	end
	spec:BuildAllDependsAndPaths()
end

-- Mutation: Add a random reachable node.
-- Returns true if successful.
function optimizer.mutateAdd(spec, pinnedNodes)
	local reachable = optimizer.getReachableNodes(spec)
	if #reachable == 0 then return false end
	local node = reachable[m_random(#reachable)]
	spec:AllocNode(node)
	return true
end

-- Mutation: Remove a random leaf node.
-- Returns true if successful.
function optimizer.mutateRemove(spec, pinnedNodes)
	local leaves = optimizer.getLeafNodes(spec, pinnedNodes)
	if #leaves == 0 then return false end
	local node = leaves[m_random(#leaves)]
	spec:DeallocNode(node)
	return true
end

-- Mutation: Swap — remove a leaf, then add a reachable node.
-- Returns true if successful.
function optimizer.mutateSwap(spec, pinnedNodes)
	if not optimizer.mutateRemove(spec, pinnedNodes) then return false end
	if not optimizer.mutateAdd(spec, pinnedNodes) then return false end
	return true
end

-- Apply a random mutation based on weights.
-- Returns true if mutation succeeded.
function optimizer.mutate(spec, pinnedNodes)
	local roll = m_random(100)
	if roll <= 40 then
		return optimizer.mutateAdd(spec, pinnedNodes)
	elseif roll <= 70 then
		return optimizer.mutateRemove(spec, pinnedNodes)
	elseif roll <= 90 then
		return optimizer.mutateSwap(spec, pinnedNodes)
	else
		-- Path shift: swap remove then add (simplified version)
		return optimizer.mutateSwap(spec, pinnedNodes)
	end
end

-- SA acceptance probability.
-- Always accepts improvements. For worse moves, probability decreases with temperature.
function optimizer.acceptanceProbability(currentScore, newScore, temperature)
	if newScore >= currentScore then
		return 1.0
	end
	return m_exp((newScore - currentScore) / m_max(temperature, 0.0001))
end

-- Count non-start allocated nodes (the "used points").
local function countUsedPoints(spec)
	local count = 0
	for id, node in pairs(spec.allocNodes) do
		if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
			count = count + 1
		end
	end
	return count
end

-- Trim excess nodes to fit within point budget.
-- Removes random leaf nodes until within budget.
local function trimToBudget(spec, pinnedNodes, budget)
	while countUsedPoints(spec) > budget do
		local leaves = optimizer.getLeafNodes(spec, pinnedNodes)
		if #leaves == 0 then break end
		local leaf = leaves[m_random(#leaves)]
		spec:DeallocNode(leaf)
	end
end

-- Evaluate a tree allocation using the calc engine.
-- The calcFunc from getMiscCalculator can accept an override with addNodes.
-- We build a set of all allocated non-start nodes to pass.
local function evaluateAlloc(calcFunc, spec)
	local addNodes = { }
	for id, node in pairs(spec.allocNodes) do
		addNodes[node] = true
	end
	return calcFunc({ addNodes = addNodes }, false)
end

-- Run Simulated Annealing optimization (synchronous, blocking).
-- params: { alpha, maxIterations, pointBudget, pinnedNodes, customWeights }
-- Returns: { bestAlloc, bestScore, iterations }
function optimizer.runSA(build, params)
	local alpha = params.alpha or 0.5
	local maxIter = params.maxIterations or 10000
	local budget = params.pointBudget or 50
	local pinned = params.pinnedNodes or {}
	local weights = params.customWeights

	local spec = build.spec

	-- Get calculator
	local calcFunc, calcBase = build.calcsTab:GetMiscCalculator()
	local baseScore = optimizer.calcScore(calcBase, calcBase, alpha, weights)

	-- Initialize from current tree
	local currentAlloc = optimizer.snapshotAlloc(spec)
	local currentScore = optimizer.calcScore(calcBase, calcBase, alpha, weights)
	local bestAlloc = optimizer.snapshotAlloc(spec)
	local bestScore = currentScore

	-- SA parameters
	local T0 = 1.0
	local coolingRate = 0.9997
	local temp = T0
	local stagnantCount = 0
	local maxStagnant = 500
	local earlyStopStagnant = 2000

	for iter = 1, maxIter do
		local prevAlloc = optimizer.snapshotAlloc(spec)

		local mutated = optimizer.mutate(spec, pinned)
		if mutated then
			trimToBudget(spec, pinned, budget)

			local output = evaluateAlloc(calcFunc, spec)
			local newScore = optimizer.calcScore(output, calcBase, alpha, weights)

			local prob = optimizer.acceptanceProbability(currentScore, newScore, temp)
			if m_random() < prob then
				currentAlloc = optimizer.snapshotAlloc(spec)
				currentScore = newScore
				if newScore > bestScore then
					bestAlloc = optimizer.snapshotAlloc(spec)
					bestScore = newScore
					stagnantCount = 0
				else
					stagnantCount = stagnantCount + 1
				end
			else
				optimizer.restoreAlloc(spec, prevAlloc)
				stagnantCount = stagnantCount + 1
			end
		else
			stagnantCount = stagnantCount + 1
		end

		temp = temp * coolingRate

		if stagnantCount >= maxStagnant and stagnantCount < earlyStopStagnant then
			temp = T0 * 0.5
			stagnantCount = 0
		end

		if stagnantCount >= earlyStopStagnant then
			optimizer.restoreAlloc(spec, bestAlloc)
			return {
				bestAlloc = bestAlloc,
				bestScore = bestScore,
				iterations = iter,
			}
		end
	end

	optimizer.restoreAlloc(spec, bestAlloc)
	return {
		bestAlloc = bestAlloc,
		bestScore = bestScore,
		iterations = maxIter,
	}
end

return optimizer
