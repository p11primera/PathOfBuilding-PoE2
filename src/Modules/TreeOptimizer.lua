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

return optimizer
