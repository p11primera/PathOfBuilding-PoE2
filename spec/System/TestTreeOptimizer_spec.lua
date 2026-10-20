-- Runaway-copy tripwire (root cause of the historical "macOS JIT wedge" and
-- the Linux shard-2 OOM deaths, diagnosed with sample/vmmap/probes):
-- PassiveSpec:SwitchAttributeNode deep-copies a SHARED passive-tree node, and
-- until the idempotence guard + keep-overrides + per-tree generation cache
-- landed, its per-call mirror generations doubled the node's reachable graph
-- every round -- one copyTableSafe memo eventually crossed LuaJIT's hard
-- 2^26 hash-node limit ("table overflow", LJ_MAX_HBITS) after ~30 GB of churn
-- and 100+ s. With at most one mirror generation per (node, option) now
-- possible, healthy copies peak at ~500 memo entries (probe census over
-- 89-208 copies per run) and the absolute worst first-switch copy is
-- ~#options x 60 tables; a 50k-entry outermost copy is therefore a definite
-- regression: fail fast, naming the caller, instead of letting the shard die
-- silently minutes later.
do
	local MAX_MEMO = 50000
	if not _G.copyTableSafeTripwire then
		local realCopy = _G.copyTableSafe
		_G.copyTableSafe = function(tbl, noRecurse, preserveMeta, isSubTable, subTableMap)
			if isSubTable or subTableMap then
				-- inner recursion frame: untouched, memo is owned by the outermost call
				return realCopy(tbl, noRecurse, preserveMeta, isSubTable, subTableMap)
			end
			local info = debug.getinfo(2, "nS") or { }
			local who = (info.name or "?") .. "@" .. tostring(info.short_src) .. ":" .. tostring(info.currentline)
			local count = 0
			local memo = setmetatable({ }, {
				__index = function(t, k) return rawget(t, k) end,
				__newindex = function(t, k, v)
					count = count + 1
					if count > MAX_MEMO then
						error(string.format(
							"copyTableSafe runaway copy: >%d memoised sub-tables (caller %s) -- a shared table is accumulating generated copies",
							MAX_MEMO, who), 0)
					end
					rawset(t, k, v)
				end,
			})
			return realCopy(tbl, noRecurse, preserveMeta, nil, memo)
		end
		_G.copyTableSafeTripwire = true
	end
end

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

	describe("connectivity helpers", function()
		it("finds leaf nodes that can be removed without disconnecting tree", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = build.spec

			-- Find and allocate a reachable node adjacent to the starting tree
			spec:BuildAllDependsAndPaths()
			local reachable = optimizer.getReachableNodes(spec)
			assert.is_true(#reachable > 0, "should have reachable nodes from start")

			-- Allocate the first reachable node
			spec:AllocNode(reachable[1])
			runCallback("OnFrame")
			spec:BuildAllDependsAndPaths()

			local leaves = optimizer.getLeafNodes(spec, {})
			assert.is_true(#leaves > 0, "should have at least one leaf after allocation")

			-- No ClassStart or AscendClassStart should appear in leaves
			for _, node in ipairs(leaves) do
				assert.is_not.equals("ClassStart", node.type)
				assert.is_not.equals("AscendClassStart", node.type)
			end
		end)

		it("finds reachable unallocated nodes", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = build.spec

			spec:BuildAllDependsAndPaths()
			local reachable = optimizer.getReachableNodes(spec)
			assert.is_true(#reachable > 0, "should find reachable nodes")

			-- All returned nodes must be unallocated and within 1 hop
			for _, node in ipairs(reachable) do
				assert.is_falsy(node.alloc)
				assert.are.equals(1, node.pathDist)
				assert.is_not.equals("ClassStart", node.type)
				assert.is_not.equals("AscendClassStart", node.type)
				assert.is_not.equals("Mastery", node.type)
			end
		end)

		it("respects pinned nodes in leaf detection", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = build.spec

			-- Allocate two nodes sequentially
			spec:BuildAllDependsAndPaths()
			local reachable = optimizer.getReachableNodes(spec)
			assert.is_true(#reachable > 0)
			spec:AllocNode(reachable[1])
			runCallback("OnFrame")
			spec:BuildAllDependsAndPaths()

			reachable = optimizer.getReachableNodes(spec)
			if #reachable > 0 then
				spec:AllocNode(reachable[1])
				runCallback("OnFrame")
				spec:BuildAllDependsAndPaths()
			end

			-- Pin all non-start allocated nodes
			local pinned = {}
			for id, node in pairs(spec.allocNodes) do
				if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
					pinned[id] = true
				end
			end

			local leaves = optimizer.getLeafNodes(spec, pinned)
			assert.are.equals(0, #leaves)
		end)
	end)

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
			local ok = optimizer.mutateAdd(spec, {})
			if ok then
				local after = countAllocNodes(spec)
				assert.is_true(after > before, "node count should increase after add")
			end
		end)

		it("mutateRemove decreases node count", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = setupTree(5)
			local before = countAllocNodes(spec)
			local ok = optimizer.mutateRemove(spec, {})
			if ok then
				local after = countAllocNodes(spec)
				assert.is_true(after < before, "node count should decrease after remove")
			end
		end)

		it("mutateRemove never removes pinned nodes", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = setupTree(5)

			-- Pin all non-start allocated nodes
			local pinned = {}
			for id, node in pairs(spec.allocNodes) do
				if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
					pinned[id] = true
				end
			end

			local ok = optimizer.mutateRemove(spec, pinned)
			assert.is_false(ok)
		end)

		it("mutateSwap keeps roughly same node count", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = setupTree(5)
			local ok = optimizer.mutateSwap(spec, {})
			if ok then
				-- Verify tree consistency: all allocNodes have alloc=true
				for id, node in pairs(spec.allocNodes) do
					assert.is_true(node.alloc, "allocated node " .. tostring(id) .. " should have alloc=true")
				end
			end
		end)

		it("mutate applies a random mutation successfully", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = setupTree(5)
			local successes = 0
			for i = 1, 10 do
				local snap = optimizer.snapshotAlloc(spec)
				local ok = optimizer.mutate(spec, {})
				if ok then
					successes = successes + 1
				end
				optimizer.restoreAlloc(spec, snap)
			end
			assert.is_true(successes > 0, "at least some mutations should succeed")
		end)
	end)

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

			local calcFunc, calcBase = build.calcsTab:GetMiscCalculator()
			local baseScore = optimizer.calcScore(calcBase, calcBase, 0.5, nil)

			local result = optimizer.runSA(build, {
				alpha = 0.5,
				maxIterations = 50,
				pointBudget = 20,
				pinnedNodes = {},
				customWeights = nil,
			})

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

			optimizer.restoreAlloc(spec, result.bestAlloc)
			local used = spec:CountAllocNodes()
			-- CountAllocNodes returns: used, ascUsed, secondaryAscUsed, sockets, ws1, ws2
			-- 'used' includes class start; budget is for non-start nodes
			assert.is_true(used <= 5 + 1) -- +1 for class start
		end)
	end)

	describe("pinned nodes", function()
		it("findNodeByName returns empty for empty query", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local results = optimizer.findNodesByName(build.spec, "")
			assert.is_true(type(results) == "table")
			assert.are.equals(0, #results)
		end)

		it("ensurePinnedAllocated allocates pinned nodes and paths", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = build.spec
			spec:BuildAllDependsAndPaths()

			-- Find a reachable Normal node within 3 hops. Collect + sort by
			-- id: a raw pairs() scan makes the picked node depend on LuaJIT
			-- table layout luck, so CI builds diverged on which node (and
			-- which code path) this test exercised.
			local candidates = { }
			for id, node in pairs(spec.nodes) do
				if not node.alloc and node.path and #node.path > 0
					and node.type == "Normal" and node.pathDist and node.pathDist <= 3 then
					table.insert(candidates, node)
				end
			end
			table.sort(candidates, function(a, b) return a.id < b.id end)
			local targetNode = candidates[1]

			if targetNode then
				local pinned = { [targetNode.id] = true }
				optimizer.ensurePinnedAllocated(spec, pinned)
				-- Self-contained failure message: never let busted build an
				-- error traceback through this 40k-node closure environment
				-- (traceback materialisation OOM-killed the CI runner once).
				if not targetNode.alloc then
					error(string.format(
						"ensurePinnedAllocated failed: target=%s pathLen=%s skippedCount=%s",
						tostring(targetNode.id),
						tostring(targetNode.path and #targetNode.path or -1),
						tostring(#{ })), 0)
				end
			end
		end)

		-- Mastery-selection hygiene: the optimizer deliberately does NOT
		-- purge stale selections (upstream owns that invariant:
		-- DeallocSingleNode nils the selection for deallocated Mastery
		-- nodes, and BuildAllDependsAndPaths sweeps ALL nodes, clearing
		-- selections on unallocated/unknown masteries -- PassiveSpec.lua
		-- ~1798-1828). A hand-rolled purge iterating
		-- pairs(masterySelections) while nilling keys was a mid-iteration
		-- mutation UB hazard and broke earlier tests for zero benefit.
		-- These tests pin the upstream invariant so a future upstream
		-- refactor fails HERE, not in the optimizer at runtime.
		it("stale mastery selection on an unallocated node is swept", function()
			local spec = build.spec
			-- any Mastery node + any recognized effect id
			local masteryNode
			for _, node in pairs(spec.nodes) do
				if node.type == "Mastery" and not node.alloc and not masteryNode then
					masteryNode = node
				end
			end
			local effectId
			for id in pairs(spec.tree.masteryEffects) do
				effectId = id
				break
			end
			if masteryNode and effectId then
				assert.is_nil(spec.allocNodes[masteryNode.id])
				spec.masterySelections[masteryNode.id] = effectId
				spec:BuildAllDependsAndPaths()
				if spec.masterySelections[masteryNode.id] ~= nil then
					error(string.format(
						"stale mastery selection survived BuildAllDependsAndPaths: node=%s effect=%s",
						tostring(masteryNode.id), tostring(effectId)), 0)
				end
			end
		end)

		it("runSA leaves no selection on unallocated mastery nodes", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local spec = build.spec
			local ok = pcall(function()
				optimizer.runSA(build, {
					alpha = 0.5,
					maxIterations = 25,
					pointBudget = 12,
					pinnedNodes = {},
					seed = 4242,
				})
			end)
			if not ok then
				error("runSA failed before mastery sweep check", 0)
			end
			for _, node in pairs(spec.nodes) do
				if node.type == "Mastery" and spec.masterySelections[node.id]
					and not spec.allocNodes[node.id] then
					error(string.format(
						"runSA left selection %s on unallocated mastery node %s",
						tostring(spec.masterySelections[node.id]),
						tostring(node.id)), 0)
				end
			end
		end)
	end)

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

	describe("integration", function()
		it("full optimization cycle improves DPS on a fresh build", function()
			newBuild()
			local spec = build.spec
			local optimizer = build.calcsTab.calcs.optimizer

			-- Capture baseline DPS through the same code path the optimizer uses
			runCallback("OnFrame")
			local function measureDPS()
				local calcFunc = build.calcsTab:GetMiscCalculator()
				local output = calcFunc({ }, true)
				return (output.FullDPS and output.FullDPS > 0 and output.FullDPS) or output.CombinedDPS or 0
			end
			local realDPS_before = measureDPS()

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

			-- runSA self-restores bestAlloc to the live spec; re-measure real DPS
			runCallback("OnFrame")
			local realDPS_after = measureDPS()

			-- Real calc output must not regress (never assert on result.bestScore)
			assert.is_true(realDPS_after >= realDPS_before)
		end)

			-- Real-world validation on an actual skill build (the "does it actually
			-- work" check): a Fireball caster gets real offensive DPS, passive
			-- points are the only variable, and there is genuine headroom -- so the
			-- gate is STRICT improvement, not the no-regression >= above. The same
			-- build also drives a deterministic greedy hill-climber built from the
			-- optimizer's own primitives (getReachableNodes/AllocNode/calcScore):
			-- greedy improving proves headroom exists, and SA's own strict
			-- improvement proves the stochastic search converts it. Both use the
			-- identical cold calcFunc closure + fast options the SA loop uses, so
			-- scores are directly comparable.
			it("strictly improves DPS on a realistic fireball build (SA + greedy control)", function()
			newBuild()
			build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
			runCallback("OnFrame")
			local spec = build.spec
			local optimizer = build.calcsTab.calcs.optimizer

			local Calcs = require("Modules.Calcs")
			local FAST = { requirementsItems = true, requirementsGems = true, skills = true }
			local function scoreOf(calcFunc, baseOutput)
				return (optimizer.calcScore(calcFunc({ }, true, FAST), baseOutput, 1.0))
			end
			local function realDPS()
				local calcFunc = build.calcsTab:GetMiscCalculator()
				local output = calcFunc({ }, true)
				return (output.FullDPS and output.FullDPS > 0 and output.FullDPS) or output.CombinedDPS or 0
			end

			local startDPS = realDPS()
			if not (startDPS > 0) then
				error(string.format("fireball build produced no DPS to optimize (startDPS=%s)",
					tostring(startDPS)), 0)
			end

			-- Deterministic greedy control: repeatedly commit the best-scoring
			-- reachable node (id order for determinism) until nothing improves.
			-- MUST rebuild depends/paths each round: getReachableNodes filters on
			-- pathDist == 1, and pathDist is only recomputed by
			-- BuildAllDependsAndPaths. Without a rebuild the frontier freezes
			-- after the first commit (newly-adjacent nodes keep a stale pathDist)
			-- and the hill-climb stalls at the isolated start -- this is exactly
			-- what runSA gets for free via initSAState -> ensurePinnedAllocated.
			local budget = 40
			do
				local calcFunc = Calcs.getMiscCalculator(build)
				spec:BuildAllDependsAndPaths()
				local baseOutput = calcFunc({ }, true, FAST)
				local rounds = 0
				local committed = 0
				while spec:CountAllocNodes() < budget and rounds < 25 do
					rounds = rounds + 1
					local cand = optimizer.getReachableNodes(spec)
					if #cand == 0 then break end
					local bestNode, bestScore
					for _, node in ipairs(cand) do
						spec:AllocNode(node)
						if spec.allocNodes[node.id] then
							local s = scoreOf(calcFunc, baseOutput)
							if not bestScore or s > bestScore then
								bestScore, bestNode = s, node
							end
							spec:DeallocSingleNode(node)
						end
					end
					if not bestNode then break end
					local currentScore = scoreOf(calcFunc, baseOutput)
					if not (bestScore > currentScore) then break end
					spec:AllocNode(bestNode)
					committed = committed + 1
					spec:BuildAllDependsAndPaths()
				end
				if committed == 0 then
					error(string.format(
						"greedy control committed nothing (rounds=%s) -- frontier frozen, not a scoring issue",
						tostring(rounds)), 0)
				end
				runCallback("OnFrame")
				local greedyDPS = realDPS()
				if not (greedyDPS > startDPS) then
					error(string.format(
						"greedy control committed %s nodes but DPS did not rise (start=%s greedy=%s)",
						tostring(committed), tostring(startDPS), tostring(greedyDPS)), 0)
				end
			end

			-- Fresh tree, then the real thing: SA must strictly improve DPS.
			newBuild()
			build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
			runCallback("OnFrame")
			local beforeDPS = realDPS()
			local result = optimizer.runSA(build, {
				alpha = 1.0,          -- pure offence: the objective IS DPS
				maxIterations = 300,
				pointBudget = 40,
				pinnedNodes = {},
				seed = 1337,
			})
			if not result then
				error("runSA returned no result on fireball build", 0)
			end
			runCallback("OnFrame")
			local afterDPS = realDPS()
			if not (afterDPS > beforeDPS) then
				error(string.format(
					"optimizer did not strictly improve DPS: before=%s after=%s (bestScore=%s iters=%s)",
					tostring(beforeDPS), tostring(afterDPS),
					tostring(result.bestScore), tostring(result.iterations)), 0)
			end
		end)

		it("undo restores original tree", function()
			newBuild()
			local spec = build.spec
			local optimizer = build.calcsTab.calcs.optimizer
			spec:BuildAllDependsAndPaths()

			-- Snapshot original
			local original = optimizer.snapshotAlloc(spec)
			local originalCount = 0
			for _ in pairs(original.nodes) do originalCount = originalCount + 1 end

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
				assert.is_true(result.bestAlloc.nodes[pinnedId] == true)
			end
		end)
	end)

	describe("hardening", function()
		it("scores candidates with an empty override diff (no double-count)", function()
			local seen = { }
			-- runSA now builds a cold closure via calcs.getMiscCalculator
			-- (not the memoised CalcsTab one), so spy on the module factory.
			local Calcs = require("Modules.Calcs")
			local realFactory = Calcs.getMiscCalculator
			Calcs.getMiscCalculator = function()
				return function(override, useFullDPS)
					table.insert(seen, { override = override, useFullDPS = useFullDPS })
					return { CombinedDPS = 1000, LifeUnreserved = 3000 }
				end
			end
			-- Restore the factory BEFORE asserting so a failed assertion
			-- cannot leave the spy installed for other specs.
			local ok, result = pcall(function()
				return build.calcsTab.calcs.optimizer.runSA(build, {
					maxIterations = 30,
					pointBudget = 10,
					seed = 42,
				})
			end)
			Calcs.getMiscCalculator = realFactory
			assert.is_true(ok, "runSA failed under spy: " .. tostring(result))
			assert.is_not_nil(result)
			assert.is_true(#seen > 0, "calcFunc should have been called at least once")
			for _, call in ipairs(seen) do
				assert.are.equal("table", type(call.override))
				assert.is_nil(next(call.override)) -- must be an EMPTY diff, keyed tables included
				assert.is_true(call.useFullDPS)
			end
		end)

		it("deterministic results with a fixed seed", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local startSnap = optimizer.snapshotAlloc(build.spec)
			local r1 = optimizer.runSA(build, {
				maxIterations = 50,
				pointBudget = 12,
				seed = 7,
			})
			optimizer.restoreAlloc(build.spec, startSnap)
			local r2 = optimizer.runSA(build, {
				maxIterations = 50,
				pointBudget = 12,
				seed = 7,
			})
			assert.are.equal(r1.bestScore, r2.bestScore)
		end)

		it("allocates pinned nodes in the synchronous runSA path", function()
			local spec = build.spec
			local optimizer = build.calcsTab.calcs.optimizer
			spec:BuildAllDependsAndPaths()

			-- Pick an unallocated Normal node exactly 1 hop from the tree
			local pinnedId = nil
			for id, node in pairs(spec.nodes) do
				if node.type == "Normal" and not node.alloc and node.pathDist == 1 then
					pinnedId = id
					break
				end
			end
			assert.is_not_nil(pinnedId, "should find a reachable Normal node")

			local result = optimizer.runSA(build, {
				maxIterations = 50,
				pointBudget = 15,
				pinnedNodes = { [pinnedId] = true },
				seed = 11,
			})
			assert.is_true(result.bestAlloc.nodes[pinnedId] == true)
		end)

		it("respects budget using game accounting", function()
			local optimizer = build.calcsTab.calcs.optimizer
			local result = optimizer.runSA(build, {
				maxIterations = 40,
				pointBudget = 8,
				seed = 5,
			})
			assert.is_true(result.iterations > 0)
			-- runSA self-restores bestAlloc to the live spec
			local used = build.spec:CountAllocNodes()
			assert.is_true(used <= 8, "game-accounted points should fit the budget, got " .. tostring(used))
		end)

		it("restoreAlloc round-trips through the PassiveSpec API", function()
			local spec = build.spec
			local optimizer = build.calcsTab.calcs.optimizer
			spec:BuildAllDependsAndPaths()

			local reachable = optimizer.getReachableNodes(spec)
			assert.is_true(#reachable > 0, "should have reachable nodes")
			spec:AllocNode(reachable[1])

			local snap = optimizer.snapshotAlloc(spec)
			local before = 0
			for _ in pairs(spec.allocNodes) do before = before + 1 end

			optimizer.restoreAlloc(spec, snap)

			local after = 0
			for _ in pairs(spec.allocNodes) do after = after + 1 end
			assert.are.equal(before, after)
			for id in pairs(snap.nodes) do
				assert.is_true(spec.allocNodes[id] ~= nil, "restored node " .. tostring(id) .. " should be allocated")
			end
		end)
	end)
end)
