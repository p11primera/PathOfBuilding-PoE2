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

-- macOS ARM64: the LuaJIT ARM64 trace compiler wedges on the SA hot loop
-- (mcode allocation storm: W^X refuses exec pages near the interpreter,
-- LuaJIT #285/#1446/#1520 family; observed as an 80+ min hang on Apple
-- Silicon). Run the optimizer hot loop in the interpreter there and
-- restore the JIT afterwards. CI proves interpreter mode completes the
-- full spec suite (997/997 in ~110s); the trace compiler stays enabled
-- for everything else.
local MAC_ARM64 = false
if jit and jit.os == "OSX" and jit.arch == "arm64" then
	MAC_ARM64 = true
end

local function runWithoutJIT(fn, ...)
	if not MAC_ARM64 then
		return fn(...)
	end
	jit.off()
	local ok, res = pcall(fn, ...)
	jit.on()
	if not ok then
		error(res, 0)
	end
	return res
end

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
	-- pairs() order over integer-keyed hash-part tables depends on the
	-- table's insert/remove history, so random indices drawn into this
	-- array would not reproduce across runs that reached the same node
	-- set via different churn. Sort: order becomes a pure function of the set.
	table.sort(reachable, function(a, b) return a.id < b.id end)
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
			and node.isFreeAllocate == nil   -- granted nodes: removing them makes no budget progress
			and not pinnedNodes[id]
			and node.depends
			and #node.depends == 1      -- only depends on itself
		then
			t_insert(leaves, node)
		end
	end
	-- see getReachableNodes: pairs() order on churned tables is history-
	-- dependent; sort so random leaf selection is reproducible.
	table.sort(leaves, function(a, b) return a.id < b.id end)
	return leaves
end

-- Snapshot current allocation (node ids + per-node state that must survive
-- restore: allocMode for weapon-set nodes, mastery selections).
-- Mastery selections live at spec-level: spec.masterySelections[nodeId] = effectId.
function optimizer.snapshotAlloc(spec)
	local snapshot = { nodes = { }, allocMode = { }, mastery = { }, path = { } }
	for id, node in pairs(spec.allocNodes) do
		snapshot.nodes[id] = true
		snapshot.allocMode[id] = node.allocMode
		-- Capture the allocation path while the node is still allocated:
		-- BuildAllDependsAndPaths only computes real paths for UNALLOCATED
		-- frontier nodes (an allocated node's path is an EMPTY table), so
		-- after a re-allocation the field is useless without this capture.
		-- Only capture non-empty paths: an empty table would shadow the
		-- BFS-recomputed path during restore.
		if node.path and #node.path > 0 then
			snapshot.path[id] = { unpack(node.path) }
		end
		if spec.masterySelections[id] then
			snapshot.mastery[id] = spec.masterySelections[id]
		end
	end
	return snapshot
end

-- Restore allocation through the PassiveSpec API (keeps allocMode,
-- multiple-choice invariants, mastery bookkeeping consistent).
function optimizer.restoreAlloc(spec, snapshot)
	local targetIds = snapshot.nodes or snapshot   -- tolerate legacy plain-set
	-- 1. deallocate everything currently allocated, one node at a time.
	-- Use DeallocSingleNode (not DeallocNode) so we don't cascade to depends
	-- or mutate hashOverrides; the clear phase removes exactly what's set.
	local toClear = { }
	for id in pairs(spec.allocNodes) do
		-- Class start nodes are permanent: upstream never deallocates them
		-- (ResetNodes preserves them; class switching handles them directly).
		-- Clearing one mid-restore loses it forever once path-fill re-allocs
		-- it, because the pre-captured target set would skip the re-add.
		local node = spec.nodes[id]
		if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
			t_insert(toClear, id)
		end
	end
	-- Keep object references: if the caller's snapshot references were taken
	-- on a stale node set, ids may name nodes that are no longer in
	-- spec.nodes; the object refs make phase 2 robust to that.
	snapshot._refs = snapshot._refs or { }
	for _, id in ipairs(toClear) do
		local node = spec.nodes[id]
		if node then
			snapshot._refs[id] = node
			spec:DeallocSingleNode(node)
		end
	end
	local ids = { }
	for id in pairs(targetIds) do
		t_insert(ids, id)
	end
	-- 2. re-allocate the target set. Start nodes go first (they have no path;
	-- upstream direct-allocates them, see PassiveSpec startNode.alloc = true).
	-- Paths MUST stay inside the snapshot set: the live BFS path is unconstrained
	-- and AllocNode(node, path) silently allocates every path node, which would
	-- add nodes outside the snapshot (breaking point budgets). The set is
	-- self-connected (it was allocated as a whole), so a set-internal path
	-- always exists once its shallower members are restored (ascending-depth order).
	local targetSet = targetIds
	local function setPathTo(target)
		local queue, from, visited = { }, { }, { }
		local head = 1
		for id in pairs(spec.allocNodes) do
			for _, other in ipairs(spec.nodes[id].linked) do
				if not other.alloc and targetSet[other.id] and not visited[other.id] then
					visited[other.id] = true
					from[other.id] = nil
					t_insert(queue, other)
				end
			end
		end
		while head <= #queue do
			local n = queue[head]
			head = head + 1
			if n == target then
				local rev, cur = { }, n
				while cur do
					t_insert(rev, cur)
					cur = from[cur.id]
				end
				local path = { }
				for i = #rev, 1, -1 do
					t_insert(path, rev[i])
				end
				return path
			end
			for _, other in ipairs(n.linked) do
				if not other.alloc and targetSet[other.id] and not visited[other.id] then
					visited[other.id] = true
					from[other.id] = n
					t_insert(queue, other)
				end
			end
		end
		return nil
	end
	local startIds, rest = { }, { }
	for _, id in ipairs(ids) do
		local node = spec.nodes[id]
		if node and not node.alloc then
			if node.type == "ClassStart" or node.type == "AscendClassStart" then
				t_insert(startIds, id)
			else
				t_insert(rest, id)
			end
		end
	end
	for _, id in ipairs(startIds) do
		local node = (snapshot._refs and snapshot._refs[id]) or spec.nodes[id]
		if node then
			node.alloc = true
			spec.allocNodes[id] = node
		end
	end
	local function restoreDepth(id)
		local captured = snapshot.path and snapshot.path[id]
		if captured and #captured > 0 then
			return #captured
		end
		local node = (snapshot._refs and snapshot._refs[id]) or spec.nodes[id]
		return node and node.pathDist or 0
	end
	table.sort(rest, function(a, b) return restoreDepth(a) < restoreDepth(b) end)
	local pending = rest
	local stallBudget = #rest + 1
	while #pending > 0 and stallBudget > 0 do
		local stillPending, progressed = { }, false
		for _, id in ipairs(pending) do
			local node = (snapshot._refs and snapshot._refs[id]) or spec.nodes[id]
			if not node or node.alloc then
				progressed = true
			else
				local path = snapshot.path and snapshot.path[id]
				if not path or #path == 0 then
					-- Never trust the live unconstrained BFS path here: it may
					-- route through nodes outside the snapshot and AllocNode
					-- would allocate them all, inflating the point count.
					path = setPathTo(node)
				end
				if path and #path > 0 and node.path then
					spec:AllocNode(node, path)
					progressed = true
				else
					t_insert(stillPending, id)
				end
			end
		end
		if not progressed then
			-- No node could advance: rebuild BFS state against what is
			-- restored so far, which will expose paths for the next frontier.
			spec:BuildAllDependsAndPaths()
			stallBudget = stallBudget - 1
		end
		pending = stillPending
	end
	-- 3. restore per-node state that AllocNode does not carry.
	if snapshot.allocMode then
		for id, mode in pairs(snapshot.allocMode) do
			local node = spec.nodes[id]
			if node then
				node.allocMode = mode
			end
		end
	end
	if snapshot.mastery then
		for id, effect in pairs(snapshot.mastery) do
			spec.masterySelections[id] = effect
		end
	end
	spec:BuildAllDependsAndPaths()
end

-- Mutation: Add a random reachable node.
-- Returns true only if the tree actually changed (AllocNode can silently
-- no-op when node.path / GetEffectiveAllocationPath is nil).
function optimizer.mutateAdd(spec, pinnedNodes)
	local reachable = optimizer.getReachableNodes(spec)
	if #reachable == 0 then return false end
	local node = reachable[m_random(#reachable)]
	if spec.allocNodes[node.id] then return false end
	spec:AllocNode(node)
	return spec.allocNodes[node.id] ~= nil
end

-- Mutation: Remove a random leaf node.
-- Returns true only if the tree actually changed.
function optimizer.mutateRemove(spec, pinnedNodes)
	local leaves = optimizer.getLeafNodes(spec, pinnedNodes)
	if #leaves == 0 then return false end
	local node = leaves[m_random(#leaves)]
	spec:DeallocNode(node)
	return spec.allocNodes[node.id] == nil
end

-- Mutation: Swap — remove a leaf, then add a reachable node.
-- On partial failure (remove succeeded, add found nothing) the spec is
-- restored, so callers never see a mutated tree reported as "no mutation".
function optimizer.mutateSwap(spec, pinnedNodes)
	local prev = optimizer.snapshotAlloc(spec)
	if not optimizer.mutateRemove(spec, pinnedNodes) then
		return false
	end
	if not optimizer.mutateAdd(spec, pinnedNodes) then
		optimizer.restoreAlloc(spec, prev)
		return false
	end
	return true
end

-- Apply a random mutation based on weights.
-- (Design's fourth operator, Path Shift, is intentionally dropped for v1:
-- it needs a real re-route algorithm; as a Swap alias it only wasted 10%
-- of iterations. Stretch goal at the end of this plan.)
function optimizer.mutate(spec, pinnedNodes)
	local roll = m_random(100)
	if roll <= 40 then
		return optimizer.mutateAdd(spec, pinnedNodes)
	elseif roll <= 70 then
		return optimizer.mutateRemove(spec, pinnedNodes)
	else
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

-- Count points used per the game's own accounting (excludes ascendancy,
-- free-allocate and start nodes, matching PassiveSpec:CountAllocNodes).
local function countUsedPoints(spec)
	return spec:CountAllocNodes()
end

-- Trim excess nodes to fit within point budget.
-- Removes random leaf nodes until within budget.
local function trimToBudget(spec, pinnedNodes, budget)
	-- Hard cap + zero-progress skipping: deallocating a leaf that
	-- CountAllocNodes doesn't charge for (granted/free nodes) makes no
	-- progress; without these guards the UI thread would hang.
	local skip = { }
	local guard = 0
	while countUsedPoints(spec) > budget and guard < 500 do
		guard = guard + 1
		local pool = { }
		for _, leaf in ipairs(optimizer.getLeafNodes(spec, pinnedNodes)) do
			if not skip[leaf.id] then
				t_insert(pool, leaf)
			end
		end
		if #pool == 0 then break end
		local before = countUsedPoints(spec)
		local leaf = pool[m_random(#pool)]
		spec:DeallocNode(leaf)
		if countUsedPoints(spec) == before then
			skip[leaf.id] = true
		end
	end
end

-- Evaluate the CURRENT live tree via a full recalc (empty override diff —
-- calcFunc overrides are applied ON TOP of the live spec, so passing the
-- already-allocated set would double-count notable/mastery modifiers).
-- useFullDPS = true matches the design doc (sustained DPS).
local function evaluateAlloc(calcFunc, spec, fastOptions)
	return calcFunc({ }, true, fastOptions)
end

-- Hot-loop accelerate flags: during an SA run only the passive tree changes
-- (items, gems, config are frozen), so only the nodeAlloc-derived state
-- needs rebuilding per evaluation. Reusing the environment (the upstream
-- accelerated path, same one the gem dropdown sorting uses) eliminates the
-- per-eval allocation storm that pushed headless CI into GC collapse.
local SA_FAST_OPTIONS = {
	requirementsItems = true,
	requirementsGems = true,
	skills = true,
}

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
	state.skippedPins = optimizer.ensurePinnedAllocated(state.spec, state.pinned)
	state.temp = state.T0
	state.stagnantCount, state.reheats, state.evalCount = 0, 0, 0
	if params.seed then m_randomseed(params.seed) end
	-- Build a FRESH misc calculator closure instead of taking the memoised
	-- CalcsTab one (GetMiscCalculator returns the closure from the last UI
	-- recalc, whose cachedPlayerDB/fullDPSStore carry stale tree state that
	-- SA's direct spec mutation never invalidates). A cold closure per run
	-- keeps identical trees scoring identically across runs (determinism).
	local calcs = require("Modules.Calcs")
	local calcFunc = calcs.getMiscCalculator(build)
	state.calcFunc = calcFunc
	state.fastOptions = SA_FAST_OPTIONS
	state.calcBase = calcFunc({ }, true, SA_FAST_OPTIONS)
	local score, offence, defence = optimizer.calcScore(state.calcBase, state.calcBase, state.alpha, state.weights)
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
		local output = evaluateAlloc(state.calcFunc, spec, state.fastOptions)
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
		skippedPins = state.skippedPins,
	}
end

-- Run Simulated Annealing optimization (synchronous, blocking).
-- params: { alpha, maxIterations, pointBudget, pinnedNodes, customWeights }
-- Returns: { bestAlloc, bestScore, iterations }
function optimizer.runSAInner(build, params)
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

-- Public entry: JIT-guarded wrapper (macOS ARM64, see runWithoutJIT).
function optimizer.runSA(build, params)
	return runWithoutJIT(optimizer.runSAInner, build, params)
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
-- Returns array of pinned node ids that could NOT be allocated (unreachable).
function optimizer.ensurePinnedAllocated(spec, pinnedNodes)
	spec:BuildAllDependsAndPaths()
	local skipped = { }
	for id in pairs(pinnedNodes) do
		local node = spec.nodes[id]
		if not node or not node.path then
			t_insert(skipped, id)
		elseif not node.alloc then
			spec:AllocNode(node)
			if not node.alloc then
				t_insert(skipped, id)
			end
		end
	end
	return skipped
end

-- Create a coroutine that runs SA and yields periodically for UI responsiveness.
-- Returns a coroutine. Resume it each frame. When dead, the return value is the final result.
-- While running, yields { progress, iteration, bestScore } tables for progress updates.
function optimizer.createOptimizerCoroutine(build, params)
	local function saCoroutineBody()
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
	end
	if not MAC_ARM64 then
		return coroutine.create(saCoroutineBody)
	end
	-- macOS ARM64: keep the trace compiler off for the SA loop's lifetime
	-- (across yields — the panel resumes this every frame). Relay through an
	-- inner coroutine: LuaJIT 5.1 cannot yield across pcall's C boundary, so
	-- error handling rides on coroutine.resume's ok/err instead.
	return coroutine.create(function()
		jit.off()
		local inner = coroutine.create(saCoroutineBody)
		while true do
			local ok, val = coroutine.resume(inner)
			if coroutine.status(inner) == "suspended" then
				if not ok then
					jit.on()
					error(val, 0)
				end
				coroutine.yield(val)  -- progress table → panel
			else
				jit.on()
				if not ok then
					error(val, 0)
				end
				return val            -- final saResult
			end
		end
	end)
end

return optimizer
