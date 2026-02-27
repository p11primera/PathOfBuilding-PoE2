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
end)
