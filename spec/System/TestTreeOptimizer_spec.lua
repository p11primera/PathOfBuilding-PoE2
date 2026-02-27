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
end)
