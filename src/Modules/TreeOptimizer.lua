-- Path of Building
--
-- Module: Tree Optimizer
-- Simulated Annealing passive tree optimizer.
--
local m_max = math.max
local m_exp = math.exp
local m_floor = math.floor
local m_random = math.random
local m_randomseed = math.randomseed
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
	local es = output.EnergyShieldRecoveryCap
	if not es or es == 0 then
		es = output.EnergyShield or 0
	end
	return (w.Life or 0) * (output.LifeUnreserved or 0) / 3000
		+ (w.EnergyShield or 0) * es / 3000
		+ (w.Armour or 0) * (output.Armour or 0) / 10000
		+ (w.Evasion or 0) * (output.Evasion or 0) / 10000
		+ (w.LifeRegen or 0) * (output.LifeRegenRecovery or 0) / 500
		+ (w.ESRegen or 0) * (output.EnergyShieldRegenRecovery or 0) / 1000
end

-- Candidate/base ratio that degrades gracefully when base == 0:
-- relative improvement when possible, bounded absolute term when not.
local function safeRatio(candidate, base, scale)
	if base > 0 then
		return candidate / base
	end
	return candidate / (candidate + scale)   -- in [0, 1) when base is 0
end

local DPS_SCALE = 1000    -- reference DPS for zero-base normalisation
local DEFENCE_SCALE = 1   -- defence metric is already O(1)-normalised

local function getDPS(output)
	local fullDPS = output.FullDPS
	if fullDPS and fullDPS > 0 then
		return fullDPS
	end
	return output.CombinedDPS or 0
end

-- Calculate weighted score combining offence and defence.
-- alpha: 0.0 = pure defence, 1.0 = pure offence.
-- customWeights: optional table overriding defence stat weights.
function optimizer.calcScore(output, baseOutput, alpha, customWeights)
	local offenceRatio = safeRatio(getDPS(output), getDPS(baseOutput), DPS_SCALE)
	local defenceRatio = safeRatio(
		optimizer.calcDefenceMetric(output, customWeights),
		optimizer.calcDefenceMetric(baseOutput, customWeights),
		DEFENCE_SCALE)
	return alpha * offenceRatio + (1 - alpha) * defenceRatio, offenceRatio, defenceRatio
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

-- Evaluate the CURRENT live tree via a full recalc (empty override diff —
-- calcFunc overrides are applied ON TOP of the live spec, so passing the
-- already-allocated set would double-count notable/mastery modifiers).
-- useFullDPS = true matches the design doc (sustained DPS).
local function evaluateAlloc(calcFunc, spec)
	return calcFunc({ }, true)
end

local SA_DEFAULTS = {
	initialTemp = 1.0,
	coolingRate = 0.9997,
	reheatFactor = 0.5,
	maxStagnant = 500,
	earlyStopStagnant = 2000,
	maxReheats = 3,
	maxIterations = 10000,
	pointBudget = 50,
	alpha = 0.5,
}

function optimizer.initSAState(build, params)
	params = params or { }
	local state = { }
	local function opt(key) return params[key] or SA_DEFAULTS[key] end
	state.alpha = opt("alpha")
	state.maxIter = opt("maxIterations")
	state.budget = opt("pointBudget")
	state.pinned = params.pinnedNodes or { }
	state.weights = params.customWeights
	state.T0 = opt("initialTemp")
	state.coolingRate = opt("coolingRate")
	state.reheatFactor = opt("reheatFactor")
	state.maxStagnant = opt("maxStagnant")
	state.earlyStopStagnant = opt("earlyStopStagnant")
	state.maxReheats = opt("maxReheats")
	state.spec = build.spec
	state.temp = state.T0
	state.stagnantCount, state.reheats, state.evalCount = 0, 0, 0
	if params.seed then m_randomseed(params.seed) end
	local calcFunc = build.calcsTab:GetMiscCalculator()
	state.calcFunc = calcFunc
	state.calcBase = calcFunc({ }, true)
	local score, offence, defence = optimizer.calcScore(calcBase, calcBase, state.alpha, state.weights)
	state.currentAlloc = optimizer.snapshotAlloc(state.spec)
	state.currentScore = score
	state.bestAlloc = optimizer.snapshotAlloc(state.spec)
	state.bestScore = score
	state.bestOffence = offence
	state.bestDefence = defence
	return state
end

-- One SA iteration. Returns "ok" or "earlystop".
function optimizer.saStep(state)
	local spec = state.spec
	local prevAlloc = optimizer.snapshotAlloc(spec)
	local mutated = optimizer.mutate(spec, state.pinned)
	if mutated then
		trimToBudget(spec, state.pinned, state.budget)
		local output = evaluateAlloc(state.calcFunc, spec)
		state.evalCount = state.evalCount + 1
		local newScore, offence, defence = optimizer.calcScore(output, state.calcBase, state.alpha, state.weights)
		local prob = optimizer.acceptanceProbability(state.currentScore, newScore, state.temp)
		if m_random() < prob then
			state.currentAlloc = optimizer.snapshotAlloc(spec)
			state.currentScore = newScore
			if newScore > state.bestScore then
				state.bestAlloc = optimizer.snapshotAlloc(spec)
				state.bestScore = newScore
				state.bestOffence = offence
				state.bestDefence = defence
				state.stagnantCount = 0
			else
				state.stagnantCount = state.stagnantCount + 1
			end
		else
			optimizer.restoreAlloc(spec, prevAlloc)
			state.stagnantCount = state.stagnantCount + 1
		end
	else
		state.stagnantCount = state.stagnantCount + 1
	end
	state.temp = state.temp * state.coolingRate
	if state.stagnantCount >= state.earlyStopStagnant then
		return "earlystop"
	end
	if state.stagnantCount >= state.maxStagnant and state.reheats < state.maxReheats then
		state.temp = state.T0 * state.reheatFactor
		state.reheats = state.reheats + 1
	end
	return "ok"
end

function optimizer.saResult(state, iter)
	return {
		bestAlloc = state.bestAlloc,
		bestScore = state.bestScore,
		bestOffence = state.bestOffence,
		bestDefence = state.bestDefence,
		iterations = iter,
		evalCount = state.evalCount,
	}
end

-- Run Simulated Annealing optimization (synchronous, blocking).
-- params: { alpha, maxIterations, pointBudget, pinnedNodes, customWeights }
-- Returns: { bestAlloc, bestScore, iterations }
function optimizer.runSA(build, params)
	local state = optimizer.initSAState(build, params)
	for iter = 1, state.maxIter do
		if optimizer.saStep(state) == "earlystop" then
			optimizer.restoreAlloc(state.spec, state.bestAlloc)
			return optimizer.saResult(state, iter)
		end
	end
	optimizer.restoreAlloc(state.spec, state.bestAlloc)
	return optimizer.saResult(state, state.maxIter)
end

-- Search for nodes by name (case-insensitive substring match).
-- Returns array of {id, name, type} for notables, keystones, and normals.
function optimizer.findNodesByName(spec, query)
	if not query or query == "" then return {} end
	local results = {}
	local lowerQuery = query:lower()
	for id, node in pairs(spec.nodes) do
		if node.dn and node.dn:lower():find(lowerQuery, 1, true) then
			if node.type == "Notable" or node.type == "Keystone" or node.type == "Normal" then
				t_insert(results, {
					id = id,
					name = node.dn,
					type = node.type,
				})
			end
		end
	end
	return results
end

-- Ensure all pinned nodes are allocated (and paths to them).
-- pinnedNodes: { [nodeId] = true }
function optimizer.ensurePinnedAllocated(spec, pinnedNodes)
	spec:BuildAllDependsAndPaths()
	for id in pairs(pinnedNodes) do
		local node = spec.nodes[id]
		if node and not node.alloc and node.path then
			spec:AllocNode(node)
		end
	end
end

-- Create a coroutine that runs SA and yields periodically for UI responsiveness.
-- Returns a coroutine. Resume it each frame. When dead, the return value is the final result.
-- While running, yields { progress, iteration, bestScore } tables for progress updates.
function optimizer.createOptimizerCoroutine(build, params)
	return coroutine.create(function()
		local state = optimizer.initSAState(build, params)
		local start = GetTime and GetTime() or os.clock() * 1000
		for iter = 1, state.maxIter do
			if optimizer.saStep(state) == "earlystop" then
				optimizer.restoreAlloc(state.spec, state.bestAlloc)
				return optimizer.saResult(state, iter)
			end
			-- Yield every ~100ms for UI responsiveness
			local now = GetTime and GetTime() or os.clock() * 1000
			if now - start > 100 then
				coroutine.yield({
					progress = iter / state.maxIter,
					iteration = iter,
					bestScore = state.bestScore,
				})
				start = now
			end
		end
		optimizer.restoreAlloc(state.spec, state.bestAlloc)
		return optimizer.saResult(state, state.maxIter)
	end)
end

return optimizer
