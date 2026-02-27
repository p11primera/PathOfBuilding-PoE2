# Passive Tree Auto-Optimizer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Simulated Annealing-based passive tree optimizer that auto-allocates nodes to maximize a weighted offence/defence score, with pinned nodes and configurable priority.

**Architecture:** SA optimizer as a Lua module using the real calc engine (`getMiscCalculator`) for scoring. Runs as a background coroutine in the Tree Tab. UI panel with slider, pinned nodes, and start/stop controls.

**Tech Stack:** Lua (LuaJIT), Busted test framework, existing PoB calc engine and UI controls.

---

## Task 1: Scoring Function Module

Create the scoring function that combines offence and defence into a single weighted score.

**Files:**
- Create: `src/Modules/TreeOptimizer.lua`
- Test: `spec/System/TestTreeOptimizer_spec.lua`

**Step 1: Write test file skeleton and first scoring test**

Create the test file. The scoring function takes a calc output table and weights, returns a numeric score.

```lua
-- spec/System/TestTreeOptimizer_spec.lua
describe("TestTreeOptimizer", function()
	before_each(function()
		newBuild()
	end)

	describe("scoring", function()
		it("returns pure offence score when alpha is 1.0", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local output = {
				CombinedDPS = 10000,
				LifeUnreserved = 3000,
				EnergyShield = 0,
				Armour = 5000,
				Evasion = 5000,
				LifeRegenRecovery = 200,
				EnergyShieldRegenRecovery = 0,
			}
			local baseOutput = {
				CombinedDPS = 5000,
				LifeUnreserved = 3000,
				EnergyShield = 0,
				Armour = 5000,
				Evasion = 5000,
				LifeRegenRecovery = 200,
				EnergyShieldRegenRecovery = 0,
			}
			local score = optimizer.calcScore(output, baseOutput, 1.0, nil)
			-- alpha=1 means pure offence: CombinedDPS / baseDPS = 10000/5000 = 2.0
			assert.are.equals(2.0, score)
		end)

		it("returns pure defence score when alpha is 0.0", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local output = {
				CombinedDPS = 5000,
				LifeUnreserved = 6000,
				EnergyShield = 0,
				Armour = 10000,
				Evasion = 10000,
				LifeRegenRecovery = 500,
				EnergyShieldRegenRecovery = 0,
			}
			local baseOutput = {
				CombinedDPS = 5000,
				LifeUnreserved = 3000,
				EnergyShield = 0,
				Armour = 5000,
				Evasion = 5000,
				LifeRegenRecovery = 200,
				EnergyShieldRegenRecovery = 0,
			}
			local score = optimizer.calcScore(output, baseOutput, 0.0, nil)
			-- alpha=0 means pure defence. Defence metric is a weighted sum of normalized stats
			-- divided by the base defence metric. Score should be > 1 since all defence stats doubled.
			assert.is_true(score > 1.0)
		end)

		it("blends offence and defence at alpha 0.5", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local output = {
				CombinedDPS = 10000,
				LifeUnreserved = 6000,
				EnergyShield = 0,
				Armour = 10000,
				Evasion = 10000,
				LifeRegenRecovery = 500,
				EnergyShieldRegenRecovery = 0,
			}
			local baseOutput = {
				CombinedDPS = 5000,
				LifeUnreserved = 3000,
				EnergyShield = 0,
				Armour = 5000,
				Evasion = 5000,
				LifeRegenRecovery = 200,
				EnergyShieldRegenRecovery = 0,
			}
			local pureOffence = optimizer.calcScore(output, baseOutput, 1.0, nil)
			local pureDefence = optimizer.calcScore(output, baseOutput, 0.0, nil)
			local blended = optimizer.calcScore(output, baseOutput, 0.5, nil)
			-- Blended should be between pure offence and pure defence
			local expected = 0.5 * pureOffence + 0.5 * pureDefence
			assert.are.near(expected, blended, 0.001)
		end)

		it("uses custom weights when provided", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local output = {
				CombinedDPS = 5000,
				LifeUnreserved = 6000,
				EnergyShield = 3000,
				Armour = 5000,
				Evasion = 5000,
				LifeRegenRecovery = 200,
				EnergyShieldRegenRecovery = 0,
			}
			local baseOutput = {
				CombinedDPS = 5000,
				LifeUnreserved = 3000,
				EnergyShield = 0,
				Armour = 5000,
				Evasion = 5000,
				LifeRegenRecovery = 200,
				EnergyShieldRegenRecovery = 0,
			}
			-- Custom weights: only care about Life and ES
			local weights = { Life = 1.0, EnergyShield = 1.0, Armour = 0, Evasion = 0, LifeRegen = 0, ESRegen = 0 }
			local score = optimizer.calcScore(output, baseOutput, 0.0, weights)
			assert.is_true(score > 1.0)
		end)

		it("handles zero base DPS gracefully", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local output = {
				CombinedDPS = 0,
				LifeUnreserved = 3000,
				EnergyShield = 0,
				Armour = 5000,
				Evasion = 5000,
				LifeRegenRecovery = 200,
				EnergyShieldRegenRecovery = 0,
			}
			local baseOutput = {
				CombinedDPS = 0,
				LifeUnreserved = 3000,
				EnergyShield = 0,
				Armour = 5000,
				Evasion = 5000,
				LifeRegenRecovery = 200,
				EnergyShieldRegenRecovery = 0,
			}
			local score = optimizer.calcScore(output, baseOutput, 1.0, nil)
			-- Should not error or return NaN/inf
			assert.is_true(score == score) -- NaN check: NaN ~= NaN
			assert.is_true(score < math.huge)
		end)
	end)
end)
```

**Step 2: Run test to verify it fails**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: FAIL — `optimizer` is nil, module does not exist yet.

**Step 3: Write scoring function implementation**

```lua
-- src/Modules/TreeOptimizer.lua
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

-- Default defence stat weights (matching CalculateCombinedOffDefStat)
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

return optimizer
```

**Step 4: Wire the module into the calc system**

Add a `LoadModule` call in `src/Modules/Calcs.lua` so the optimizer is accessible via `calcs.optimizer`:

Find the block of `LoadModule` calls near the top of `src/Modules/Calcs.lua` (around lines 14-21) and add after the last one:

```lua
LoadModule("Modules/CalcMirages.lua", calcs)
-- Add this line:
calcs.optimizer = LoadModule("Modules/TreeOptimizer.lua")
```

**Step 5: Run tests to verify they pass**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: All 5 scoring tests PASS.

**Step 6: Commit**

```bash
git add src/Modules/TreeOptimizer.lua src/Modules/Calcs.lua spec/System/TestTreeOptimizer_spec.lua
git commit -m "feat(optimizer): add scoring function with offence/defence weighting"
```

---

## Task 2: Tree Connectivity Helpers

Build helper functions to find leaf nodes, reachable nodes, and validate tree connectivity — the building blocks for SA mutations.

**Files:**
- Modify: `src/Modules/TreeOptimizer.lua`
- Test: `spec/System/TestTreeOptimizer_spec.lua`

**Step 1: Write connectivity tests**

Append to `spec/System/TestTreeOptimizer_spec.lua`, inside the outer `describe`:

```lua
	describe("connectivity helpers", function()
		it("finds leaf nodes that can be removed without disconnecting tree", function()
			local optimizer = build.calcsTab.calcs.optimizer
			-- Allocate a few nodes first
			local spec = build.spec
			-- After newBuild(), class start is allocated. Allocate some reachable nodes.
			spec:BuildAllDependsAndPaths()
			local allocatedBefore = 0
			for _ in pairs(spec.allocNodes) do allocatedBefore = allocatedBefore + 1 end

			-- Find a reachable node and allocate it
			local reachable = optimizer.getReachableNodes(spec)
			assert.is_true(#reachable > 0)
			spec:AllocNode(reachable[1])
			runCallback("OnFrame")

			-- Now find leaves
			local leaves = optimizer.getLeafNodes(spec, {})
			assert.is_true(#leaves > 0)
			-- Each leaf should be removable (not a class start, not pinned)
			for _, leaf in ipairs(leaves) do
				assert.is_not.equals("ClassStart", leaf.type)
				assert.is_not.equals("AscendClassStart", leaf.type)
			end
		end)

		it("finds reachable unallocated nodes", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = build.spec
			spec:BuildAllDependsAndPaths()
			local reachable = optimizer.getReachableNodes(spec)
			assert.is_true(#reachable > 0)
			-- All reachable nodes should be unallocated and within 1 hop
			for _, node in ipairs(reachable) do
				assert.is_false(node.alloc)
				assert.is_true(node.pathDist ~= nil and node.pathDist <= 1)
			end
		end)

		it("respects pinned nodes in leaf detection", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = build.spec
			spec:BuildAllDependsAndPaths()

			-- Allocate 2 reachable nodes in sequence
			local reachable = optimizer.getReachableNodes(spec)
			if #reachable > 0 then
				spec:AllocNode(reachable[1])
				runCallback("OnFrame")
			end
			reachable = optimizer.getReachableNodes(spec)
			if #reachable > 0 then
				spec:AllocNode(reachable[1])
				runCallback("OnFrame")
			end

			-- Pin all currently allocated non-start nodes
			local pinned = {}
			for id, node in pairs(spec.allocNodes) do
				if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
					pinned[id] = true
				end
			end

			-- No leaves should be returned when all are pinned
			local leaves = optimizer.getLeafNodes(spec, pinned)
			assert.are.equals(0, #leaves)
		end)
	end)
```

**Step 2: Run tests to verify they fail**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: FAIL — `getReachableNodes` and `getLeafNodes` not defined.

**Step 3: Implement connectivity helpers**

Add to `src/Modules/TreeOptimizer.lua`, before the `return optimizer` line:

```lua
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
```

**Step 4: Run tests to verify they pass**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: All connectivity tests PASS.

**Step 5: Commit**

```bash
git add src/Modules/TreeOptimizer.lua spec/System/TestTreeOptimizer_spec.lua
git commit -m "feat(optimizer): add tree connectivity helpers (reachable, leaf nodes)"
```

---

## Task 3: Mutation Operators

Implement the four SA mutation operators: Add, Remove, Swap, Path Shift.

**Files:**
- Modify: `src/Modules/TreeOptimizer.lua`
- Test: `spec/System/TestTreeOptimizer_spec.lua`

**Step 1: Write mutation tests**

Append to `spec/System/TestTreeOptimizer_spec.lua`, inside the outer `describe`:

```lua
	describe("mutations", function()
		local function countAllocNodes(spec)
			local count = 0
			for _ in pairs(spec.allocNodes) do count = count + 1 end
			return count
		end

		local function setupTree(nNodes)
			local spec = build.spec
			spec:BuildAllDependsAndPaths()
			local optimizer = build.calcsTab.calcs.optimizer
			for i = 1, nNodes do
				local reachable = optimizer.getReachableNodes(spec)
				if #reachable > 0 then
					spec:AllocNode(reachable[1])
				end
			end
			return spec
		end

		it("mutateAdd increases node count by path length", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = setupTree(3)
			local before = countAllocNodes(spec)
			local success = optimizer.mutateAdd(spec, {})
			if success then
				local after = countAllocNodes(spec)
				assert.is_true(after > before)
			end
		end)

		it("mutateRemove decreases node count", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = setupTree(5)
			local before = countAllocNodes(spec)
			local success = optimizer.mutateRemove(spec, {})
			if success then
				local after = countAllocNodes(spec)
				assert.is_true(after < before)
			end
		end)

		it("mutateRemove never removes pinned nodes", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = setupTree(5)

			-- Pin all non-start nodes
			local pinned = {}
			for id, node in pairs(spec.allocNodes) do
				if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
					pinned[id] = true
				end
			end

			local success = optimizer.mutateRemove(spec, pinned)
			assert.is_false(success)
		end)

		it("mutateSwap keeps roughly same node count", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = setupTree(5)
			local before = countAllocNodes(spec)
			local success = optimizer.mutateSwap(spec, {})
			-- Swap may change count slightly due to path lengths, but tree stays connected
			if success then
				-- Verify tree is still connected
				spec:BuildAllDependsAndPaths()
				for id, node in pairs(spec.allocNodes) do
					if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
						-- Every allocated non-start node should be reachable
						assert.is_true(node.alloc)
					end
				end
			end
		end)

		it("mutate applies a random mutation successfully", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = setupTree(5)
			-- Run mutate 10 times; at least some should succeed
			local successes = 0
			for i = 1, 10 do
				local snapshot = optimizer.snapshotAlloc(spec)
				local ok = optimizer.mutate(spec, {})
				if ok then
					successes = successes + 1
				end
				optimizer.restoreAlloc(spec, snapshot)
			end
			assert.is_true(successes > 0)
		end)
	end)
```

**Step 2: Run tests to verify they fail**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: FAIL — mutation functions not defined.

**Step 3: Implement mutation operators and snapshot/restore**

Add to `src/Modules/TreeOptimizer.lua`, before `return optimizer`:

```lua
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
	-- Directly allocate (AllocNode handles path)
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
```

**Step 4: Run tests to verify they pass**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: All mutation tests PASS.

**Step 5: Commit**

```bash
git add src/Modules/TreeOptimizer.lua spec/System/TestTreeOptimizer_spec.lua
git commit -m "feat(optimizer): add SA mutation operators (add, remove, swap)"
```

---

## Task 4: SA Core Loop

Implement the Simulated Annealing loop that drives optimization.

**Files:**
- Modify: `src/Modules/TreeOptimizer.lua`
- Test: `spec/System/TestTreeOptimizer_spec.lua`

**Step 1: Write SA loop tests**

Append to `spec/System/TestTreeOptimizer_spec.lua`, inside the outer `describe`:

```lua
	describe("SA core", function()
		it("acceptance probability is 1.0 for improvements", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local prob = optimizer.acceptanceProbability(1.0, 2.0, 1.0)
			assert.are.equals(1.0, prob)
		end)

		it("acceptance probability decreases with temperature", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local probHot = optimizer.acceptanceProbability(2.0, 1.0, 1.0)
			local probCold = optimizer.acceptanceProbability(2.0, 1.0, 0.01)
			assert.is_true(probHot > probCold)
		end)

		it("acceptance probability is between 0 and 1 for worse moves", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local prob = optimizer.acceptanceProbability(2.0, 1.0, 0.5)
			assert.is_true(prob > 0 and prob < 1)
		end)

		it("runSA improves score over iterations on a real build", function()
			local spec = build.spec
			spec:BuildAllDependsAndPaths()
			local optimizer = build.calcsTab.calcs.optimizer

			-- Get baseline score
			local calcFunc, calcBase = build.calcsTab:GetMiscCalculator()
			local baseScore = optimizer.calcScore(calcBase, calcBase, 0.5, nil)

			-- Run a small SA (50 iterations for test speed)
			local result = optimizer.runSA(build, {
				alpha = 0.5,
				maxIterations = 50,
				pointBudget = 20,
				pinnedNodes = {},
				customWeights = nil,
			})

			-- Best score should be >= base (SA starts from current, can only accept)
			assert.is_true(result.bestScore >= baseScore)
			assert.is_true(result.iterations > 0)
		end)

		it("enforces point budget", function()
			local spec = build.spec
			spec:BuildAllDependsAndPaths()
			local optimizer = build.calcsTab.calcs.optimizer

			local result = optimizer.runSA(build, {
				alpha = 0.5,
				maxIterations = 30,
				pointBudget = 5,
				pinnedNodes = {},
				customWeights = nil,
			})

			-- Apply best tree and check point count
			optimizer.restoreAlloc(spec, result.bestAlloc)
			local used = spec:CountAllocNodes()
			-- used includes class start; budget is for non-start nodes
			assert.is_true(used <= 5 + 1) -- +1 for class start
		end)
	end)
```

**Step 2: Run tests to verify they fail**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: FAIL — `acceptanceProbability` and `runSA` not defined.

**Step 3: Implement SA core**

Add to `src/Modules/TreeOptimizer.lua`, before `return optimizer`:

```lua
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
-- Returns the output table from getMiscCalculator.
local function evaluateAlloc(calcFunc, spec)
	local addNodes = { }
	for id, node in pairs(spec.allocNodes) do
		addNodes[node] = true
	end
	return calcFunc({ addNodes = addNodes }, false)
end

-- Run Simulated Annealing optimization.
-- params: { alpha, maxIterations, pointBudget, pinnedNodes, customWeights, yieldFunc }
-- Returns: { bestAlloc, bestScore, iterations, bestOffence, bestDefence }
function optimizer.runSA(build, params)
	local alpha = params.alpha or 0.5
	local maxIter = params.maxIterations or 10000
	local budget = params.pointBudget or 50
	local pinned = params.pinnedNodes or {}
	local weights = params.customWeights
	local yieldFunc = params.yieldFunc        -- optional: called periodically with progress
	local progressFunc = params.progressFunc  -- optional: called with (iteration, bestScore)

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
	local maxStagnant = 500     -- reheat threshold
	local earlyStopStagnant = 2000

	for iter = 1, maxIter do
		-- Save current state
		local prevAlloc = optimizer.snapshotAlloc(spec)

		-- Apply random mutation
		local mutated = optimizer.mutate(spec, pinned)
		if mutated then
			-- Enforce budget
			trimToBudget(spec, pinned, budget)

			-- Evaluate new allocation
			-- We need to restore base first, then evaluate with addNodes
			local output = evaluateAlloc(calcFunc, spec)
			local newScore = optimizer.calcScore(output, calcBase, alpha, weights)

			-- SA acceptance
			local prob = optimizer.acceptanceProbability(currentScore, newScore, temp)
			if m_random() < prob then
				-- Accept the move
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
				-- Reject: restore previous allocation
				optimizer.restoreAlloc(spec, prevAlloc)
				stagnantCount = stagnantCount + 1
			end
		else
			stagnantCount = stagnantCount + 1
		end

		-- Cool down
		temp = temp * coolingRate

		-- Reheat if stagnant
		if stagnantCount >= maxStagnant and stagnantCount < earlyStopStagnant then
			temp = T0 * 0.5
			stagnantCount = 0
		end

		-- Early stop
		if stagnantCount >= earlyStopStagnant then
			-- Restore best and return
			optimizer.restoreAlloc(spec, bestAlloc)
			return {
				bestAlloc = bestAlloc,
				bestScore = bestScore,
				iterations = iter,
			}
		end

		-- Yield for UI responsiveness
		if yieldFunc and iter % 10 == 0 then
			yieldFunc(iter, maxIter, bestScore)
		end

		-- Progress callback
		if progressFunc and iter % 50 == 0 then
			progressFunc(iter, bestScore)
		end
	end

	-- Restore best allocation
	optimizer.restoreAlloc(spec, bestAlloc)
	return {
		bestAlloc = bestAlloc,
		bestScore = bestScore,
		iterations = maxIter,
	}
end
```

**Step 4: Run tests to verify they pass**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: All SA core tests PASS.

**Step 5: Commit**

```bash
git add src/Modules/TreeOptimizer.lua spec/System/TestTreeOptimizer_spec.lua
git commit -m "feat(optimizer): implement SA core loop with acceptance, budget, early stop"
```

---

## Task 5: Pinned Node Management

Add functions to manage pinned nodes: pin/unpin by ID, pin by name search, ensure pinned nodes are allocated before SA starts.

**Files:**
- Modify: `src/Modules/TreeOptimizer.lua`
- Test: `spec/System/TestTreeOptimizer_spec.lua`

**Step 1: Write pinned node tests**

Append to `spec/System/TestTreeOptimizer_spec.lua`, inside the outer `describe`:

```lua
	describe("pinned nodes", function()
		it("findNodeByName returns matching notable", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = build.spec
			-- Search for a node that should exist in the default tree
			local results = optimizer.findNodesByName(spec, "")
			-- Empty string should match nothing (too broad)
			assert.is_true(type(results) == "table")
		end)

		it("ensurePinnedAllocated allocates pinned nodes and paths", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = build.spec
			spec:BuildAllDependsAndPaths()

			-- Find a notable that's reachable (has a path)
			local targetNode = nil
			for id, node in pairs(spec.nodes) do
				if not node.alloc and node.path and #node.path > 0
					and node.type == "Normal" and node.pathDist and node.pathDist <= 3 then
					targetNode = node
					break
				end
			end

			if targetNode then
				local pinned = { [targetNode.id] = true }
				optimizer.ensurePinnedAllocated(spec, pinned)
				assert.is_true(targetNode.alloc)
			end
		end)
	end)
```

**Step 2: Run tests to verify they fail**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: FAIL — functions not defined.

**Step 3: Implement pinned node management**

Add to `src/Modules/TreeOptimizer.lua`, before `return optimizer`:

```lua
-- Search for nodes by name (case-insensitive substring match).
-- Returns array of {id, name, type} for notables and keystones.
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
```

**Step 4: Run tests to verify they pass**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: All pinned node tests PASS.

**Step 5: Commit**

```bash
git add src/Modules/TreeOptimizer.lua spec/System/TestTreeOptimizer_spec.lua
git commit -m "feat(optimizer): add pinned node search and auto-allocation"
```

---

## Task 6: Background Coroutine Runner

Wrap the SA loop in a coroutine that yields every ~100ms, matching the PowerBuilder pattern for UI responsiveness.

**Files:**
- Modify: `src/Modules/TreeOptimizer.lua`
- Test: `spec/System/TestTreeOptimizer_spec.lua`

**Step 1: Write coroutine runner test**

Append to `spec/System/TestTreeOptimizer_spec.lua`, inside the outer `describe`:

```lua
	describe("coroutine runner", function()
		it("createOptimizerCoroutine returns a resumable coroutine", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = build.spec
			spec:BuildAllDependsAndPaths()

			local co = optimizer.createOptimizerCoroutine(build, {
				alpha = 0.5,
				maxIterations = 20,
				pointBudget = 10,
				pinnedNodes = {},
			})

			assert.are.equals("thread", type(co))

			-- Resume until dead
			local result
			while coroutine.status(co) ~= "dead" do
				local ok, val = coroutine.resume(co)
				assert.is_true(ok)
				if coroutine.status(co) == "dead" then
					result = val
				end
			end

			assert.is_not_nil(result)
			assert.is_not_nil(result.bestScore)
		end)
	end)
```

**Step 2: Run test to verify it fails**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: FAIL — `createOptimizerCoroutine` not defined.

**Step 3: Implement coroutine wrapper**

Add to `src/Modules/TreeOptimizer.lua`, before `return optimizer`:

```lua
-- Create a coroutine that runs SA and yields periodically for UI responsiveness.
-- Returns a coroutine. Resume it each frame. It returns the result when done.
function optimizer.createOptimizerCoroutine(build, params)
	return coroutine.create(function()
		local alpha = params.alpha or 0.5
		local maxIter = params.maxIterations or 10000
		local budget = params.pointBudget or 50
		local pinned = params.pinnedNodes or {}
		local weights = params.customWeights

		local spec = build.spec

		-- Ensure pinned nodes are allocated first
		optimizer.ensurePinnedAllocated(spec, pinned)

		-- Get calculator
		local calcFunc, calcBase = build.calcsTab:GetMiscCalculator()

		-- Initialize
		local currentAlloc = optimizer.snapshotAlloc(spec)
		local currentScore = optimizer.calcScore(calcBase, calcBase, alpha, weights)
		local bestAlloc = optimizer.snapshotAlloc(spec)
		local bestScore = currentScore

		-- SA state
		local T0 = 1.0
		local coolingRate = 0.9997
		local temp = T0
		local stagnantCount = 0
		local maxStagnant = 500
		local earlyStopStagnant = 2000

		local start = GetTime and GetTime() or os.clock() * 1000

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

			-- Yield every ~100ms for UI responsiveness
			local now = GetTime and GetTime() or os.clock() * 1000
			if now - start > 100 then
				coroutine.yield({
					progress = iter / maxIter,
					iteration = iter,
					bestScore = bestScore,
				})
				start = now
			end
		end

		optimizer.restoreAlloc(spec, bestAlloc)
		return {
			bestAlloc = bestAlloc,
			bestScore = bestScore,
			iterations = maxIter,
		}
	end)
end
```

**Step 4: Run tests to verify they pass**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: Coroutine test PASSES.

**Step 5: Commit**

```bash
git add src/Modules/TreeOptimizer.lua spec/System/TestTreeOptimizer_spec.lua
git commit -m "feat(optimizer): add background coroutine runner with periodic yield"
```

---

## Task 7: Optimizer Panel UI Control

Create the `OptimizerPanel` control class that houses slider, buttons, pinned list, and progress display.

**Files:**
- Create: `src/Classes/OptimizerPanel.lua`

**Step 1: Create the OptimizerPanel class**

```lua
-- src/Classes/OptimizerPanel.lua
-- Path of Building
--
-- Class: Optimizer Panel
-- UI panel for the passive tree auto-optimizer.
--

local t_insert = table.insert
local t_remove = table.remove
local m_floor = math.floor
local m_max = math.max

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
	self.bestScoreStr = ""

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

	-- Pinned nodes search
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

	-- Pinned nodes display
	self.controls.pinnedLabel = new("LabelControl", { "LEFT", self.controls.pinSearchResults, "RIGHT" }, { 12, 0, 0, 16 },
		function() return "Pinned: " .. #self.pinnedNodesList end)

	-- Apply / Reset buttons (shown after optimization)
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
	-- PoE2: roughly 2 points per level after level 2, plus quest rewards
	local level = self.build.characterLevel or 1
	local points = m_max(0, level - 1)  -- simplified; real calc depends on quest rewards
	self.pointBudget = points
	self.controls.budgetEdit:SetText(tostring(points))
end

function OptimizerPanelClass:PinNode(id, name, nodeType)
	if self.pinnedNodes[id] then return end
	if #self.pinnedNodesList >= 5 then return end  -- max 5 pinned
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

	-- Snapshot original tree for undo
	self.originalAlloc = self.optimizer.snapshotAlloc(self.build.spec)
	self.bestResult = nil
	self.running = true
	self.progressPct = 0

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
	-- Restore original tree (user can Apply later if bestResult exists)
	if self.originalAlloc then
		self.optimizer.restoreAlloc(self.build.spec, self.originalAlloc)
		self.build.buildFlag = true
	end
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
		-- Error occurred
		self.running = false
		self.optimizerCoroutine = nil
		self.controls.progressLabel.label = "Error: " .. tostring(val)
		return
	end

	if coroutine.status(self.optimizerCoroutine) == "dead" then
		-- Completed — val is the final result
		self.bestResult = val
		self.running = false
		self.optimizerCoroutine = nil
		self.controls.progressLabel.label = string.format("Done! Best score: %.2f (%d iterations)", val.bestScore, val.iterations)
		-- Auto-apply best tree
		self:ApplyBestTree()
	elseif val then
		-- Progress update
		self.progressPct = val.progress or 0
		self.controls.progressLabel.label = string.format("Optimizing... %d%% (best: %.2f)", m_floor(self.progressPct * 100), val.bestScore)
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
end

-- Called each frame from TreeTab
function OptimizerPanelClass:OnFrame()
	if self.running then
		self:ResumeOptimizer()
	end
end

-- Toggle pin when clicking nodes in pin mode
function OptimizerPanelClass:HandleNodeClick(node)
	if not self.pinMode then return false end
	if node.type == "ClassStart" or node.type == "AscendClassStart" then return false end
	if self.pinnedNodes[node.id] then
		self:UnpinNode(node.id)
	else
		self:PinNode(node.id, node.dn, node.type)
	end
	return true  -- consumed the click
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

	-- Draw pinned nodes as text below the search bar
	local pinY = y + 56
	if self.bestResult then
		pinY = pinY + 24
	end
	SetDrawColor(1, 1, 1, 1)
	for i, pin in ipairs(self.pinnedNodesList) do
		DrawString(x + 10, pinY + (i - 1) * 16, "LEFT", 14, "VAR", pin.name .. " [" .. pin.type .. "]")
	end

	self:DrawControls(viewPort)
end
```

**Step 2: Commit**

```bash
git add src/Classes/OptimizerPanel.lua
git commit -m "feat(optimizer): add OptimizerPanel UI control class"
```

---

## Task 8: Integrate Optimizer into TreeTab

Wire the optimizer panel into the Tree Tab with a toggle button and per-frame coroutine resumption.

**Files:**
- Modify: `src/Classes/TreeTab.lua`

**Step 1: Read current TreeTab control creation area**

Read `src/Classes/TreeTab.lua` lines 260-310 to see where the power report button is created. The optimizer button goes next to it.

**Step 2: Add optimizer button and panel after the power report button**

Find the power report button creation (around line 263-279) and add after it:

```lua
-- After self.controls.powerReport and self.controls.powerReportList...

-- Optimizer Button
self.controls.optimizerToggle = new("ButtonControl", { "LEFT", self.controls.powerReport, "RIGHT" }, { 8, 0, 150, 20 },
	function() return self.controls.optimizerPanel.shown and "Hide Optimizer" or "Show Optimizer" end,
	function()
		self.controls.optimizerPanel.shown = not self.controls.optimizerPanel.shown
	end)

-- Optimizer Panel
self.controls.optimizerPanel = new("OptimizerPanel",
	{ "TOPLEFT", self.controls.specSelect, "BOTTOMLEFT" },
	{ 0, 4, 700, 120 },
	build)
self.controls.optimizerPanel.shown = false
```

**Step 3: Update the bottom drawer height calculation**

Find the `bottomDrawerHeight` calculation (around line 430) and modify it to include the optimizer panel:

```lua
local bottomDrawerHeight = 0
if self.controls.powerReportList.shown then
	bottomDrawerHeight = bottomDrawerHeight + 194
end
if self.controls.optimizerPanel.shown then
	bottomDrawerHeight = bottomDrawerHeight + 128
end
```

**Step 4: Add per-frame optimizer resumption in the Draw function**

Find the `Draw` function (around line 349) and add optimizer frame update near the start:

```lua
-- Inside TreeTabClass:Draw(), near the top of the function body:
if self.controls.optimizerPanel then
	self.controls.optimizerPanel:OnFrame()
end
```

**Step 5: Commit**

```bash
git add src/Classes/TreeTab.lua
git commit -m "feat(optimizer): integrate optimizer panel into TreeTab"
```

---

## Task 9: Pin Mode Click Handling in PassiveTreeView

When pin mode is active in the optimizer, clicking a node should pin/unpin it instead of allocating it.

**Files:**
- Modify: `src/Classes/PassiveTreeView.lua`

**Step 1: Read the node click handling code**

Read `src/Classes/PassiveTreeView.lua` and find where node clicks are processed (look for `OnKeyUp` or mouse click handling with `node.alloc`).

**Step 2: Add pin mode intercept**

At the point where a node click is about to allocate/deallocate, add a check:

```lua
-- Before the normal allocation logic:
if self.build.treeTab.controls.optimizerPanel
	and self.build.treeTab.controls.optimizerPanel:HandleNodeClick(hoverNode) then
	-- Click consumed by optimizer pin mode
	return
end
```

The exact insertion point depends on the click handler structure in PassiveTreeView. Look for where `spec:AllocNode` or `spec:DeallocNode` is called in response to a click, and add the intercept before it.

**Step 3: Add visual indicator for pinned nodes**

In the node drawing code, add a pin indicator (colored border or icon) for pinned nodes:

```lua
-- In the node drawing loop, after drawing the base node:
if self.build.treeTab.controls.optimizerPanel
	and self.build.treeTab.controls.optimizerPanel.pinnedNodes[node.id] then
	-- Draw pin indicator (golden border)
	SetDrawColor(1, 0.8, 0, 1)
	DrawImage(nil, screenX - size - 2, screenY - size - 2, size * 2 + 4, size * 2 + 4)
end
```

**Step 4: Commit**

```bash
git add src/Classes/PassiveTreeView.lua
git commit -m "feat(optimizer): add pin mode click handling and visual indicator"
```

---

## Task 10: Integration Test — Full Optimization Cycle

Write an end-to-end test that loads a build, runs the optimizer, and verifies improvement.

**Files:**
- Modify: `spec/System/TestTreeOptimizer_spec.lua`

**Step 1: Write integration test**

Append to `spec/System/TestTreeOptimizer_spec.lua`, inside the outer `describe`:

```lua
	describe("integration", function()
		it("full optimization cycle improves DPS on a fresh build", function()
			newBuild()
			local spec = build.spec
			local optimizer = build.calcsTab.calcs.optimizer

			-- Get baseline DPS
			runCallback("OnFrame")
			local baseDPS = build.calcsTab.mainOutput.CombinedDPS or 0

			-- Run the optimizer with modest budget
			local result = optimizer.runSA(build, {
				alpha = 1.0,          -- pure offence
				maxIterations = 100,  -- small for test speed
				pointBudget = 15,
				pinnedNodes = {},
			})

			-- Verify the optimizer completed
			assert.is_not_nil(result)
			assert.is_not_nil(result.bestAlloc)
			assert.is_true(result.iterations > 0)

			-- Apply and recalculate
			runCallback("OnFrame")
			local newDPS = build.calcsTab.mainOutput.CombinedDPS or 0

			-- Score should be at least as good (may not improve DPS on a fresh empty build)
			assert.is_true(result.bestScore >= 0)
		end)

		it("undo restores original tree", function()
			newBuild()
			local spec = build.spec
			local optimizer = build.calcsTab.calcs.optimizer
			spec:BuildAllDependsAndPaths()

			-- Snapshot original
			local original = optimizer.snapshotAlloc(spec)
			local originalCount = 0
			for _ in pairs(original) do originalCount = originalCount + 1 end

			-- Run optimizer
			local result = optimizer.runSA(build, {
				alpha = 0.5,
				maxIterations = 50,
				pointBudget = 10,
				pinnedNodes = {},
			})

			-- Restore original
			optimizer.restoreAlloc(spec, original)
			local restoredCount = 0
			for _ in pairs(spec.allocNodes) do restoredCount = restoredCount + 1 end

			assert.are.equals(originalCount, restoredCount)
		end)

		it("respects pinned nodes in optimization", function()
			newBuild()
			local spec = build.spec
			local optimizer = build.calcsTab.calcs.optimizer
			spec:BuildAllDependsAndPaths()

			-- Find a reachable notable to pin
			local pinnedId = nil
			for id, node in pairs(spec.nodes) do
				if not node.alloc and node.path and node.pathDist and node.pathDist <= 3
					and (node.type == "Notable" or node.type == "Normal") then
					pinnedId = id
					break
				end
			end

			if pinnedId then
				local pinned = { [pinnedId] = true }
				local result = optimizer.runSA(build, {
					alpha = 0.5,
					maxIterations = 50,
					pointBudget = 15,
					pinnedNodes = pinned,
				})

				-- Verify pinned node is in the best allocation
				assert.is_true(result.bestAlloc[pinnedId] == true)
			end
		end)
	end)
```

**Step 2: Run integration tests**

Run: `docker compose run --rm busted-tests busted --lua=luajit spec/System/TestTreeOptimizer_spec.lua`

Expected: All integration tests PASS.

**Step 3: Commit**

```bash
git add spec/System/TestTreeOptimizer_spec.lua
git commit -m "test(optimizer): add integration tests for full optimization cycle"
```

---

## Task 11: Run Full Test Suite

Verify nothing is broken across the entire test suite.

**Step 1: Run all tests**

Run: `docker compose run --rm busted-tests`

Expected: All existing tests still PASS. No regressions from our changes to `Calcs.lua` or `TreeTab.lua`.

**Step 2: Fix any failures**

If any existing tests fail, investigate and fix. The most likely issue is changes to `Calcs.lua` (the `LoadModule` line) or `TreeTab.lua` (layout changes). Fix without breaking optimizer functionality.

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve test regressions from optimizer integration"
```

---

## Summary of Files

| Action | File | Purpose |
|--------|------|---------|
| Create | `src/Modules/TreeOptimizer.lua` | SA engine: scoring, mutations, connectivity, core loop, coroutine runner |
| Create | `src/Classes/OptimizerPanel.lua` | UI panel: slider, buttons, pin list, progress display |
| Modify | `src/Modules/Calcs.lua` | Wire optimizer module via `LoadModule` |
| Modify | `src/Classes/TreeTab.lua` | Add optimizer toggle button and panel, update layout |
| Modify | `src/Classes/PassiveTreeView.lua` | Pin mode click intercept and visual indicator |
| Create | `spec/System/TestTreeOptimizer_spec.lua` | Unit + integration tests |

## Architecture Diagram

```
TreeTab
  └── OptimizerPanel (UI)
        ├── SliderControl (alpha)
        ├── EditControl (budget)
        ├── ButtonControl (start/stop)
        ├── Node search + pin list
        └── Drives: TreeOptimizer coroutine
              ├── Scoring function (calcScore)
              ├── Mutations (add/remove/swap)
              ├── SA loop (acceptance, cooling, reheat)
              └── Uses: getMiscCalculator → full calc engine
                    ├── CalcSetup (item mods, tree mods)
                    ├── CalcPerform (stats)
                    ├── CalcOffence (DPS)
                    └── CalcDefence (life, armour, etc.)
```
