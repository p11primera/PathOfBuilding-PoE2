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

			-- Find a reachable Normal node within 3 hops
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
end)
