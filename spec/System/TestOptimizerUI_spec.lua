-- Smoke tests for the optimizer UI layer. These construct the real TreeTab
-- + OptimizerPanel via newBuild(); the original three startup crashes
-- (legacy new() ctor args, calcsTab-before-init ordering, nil self.build)
-- all surface here.
describe("TestOptimizerUI", { tags = "optimizer" }, function()
	before_each(function()
		newBuild()
	end)

	describe("TreeTab construction", function()
		it("constructs with the optimizer controls", function()
			assert.is_not_nil(build.treeTab)
			assert.is_not_nil(build.treeTab.controls.optimizerPanel)
			assert.is_not_nil(build.treeTab.controls.optimizerToggle)
			assert.is_false(build.treeTab.controls.optimizerPanel.shown)
		end)
	end)

	describe("panel pin flow", function()
		it("pins and unpins through its own API", function()
			local panel = build.treeTab.controls.optimizerPanel
			local spec = build.spec
			local id, name
			for nid, node in pairs(spec.nodes) do
				if node.type == "Normal" then
					id, name = nid, node.dn
					break
				end
			end
			assert.is_not_nil(id, "should find a Normal node")

			panel:PinNode(id, name, "Normal")
			assert.is_true(panel.pinnedNodes[id])
			assert.are.equal(1, #panel.pinnedNodesList)
			assert.is_not_nil(panel.controls["pinBtn" .. id])

			panel:UnpinNode(id)
			assert.is_nil(panel.pinnedNodes[id])
			assert.is_nil(panel.controls["pinBtn" .. id])
		end)

		it("HandleNodeClick toggles pins only in pin mode", function()
			local panel = build.treeTab.controls.optimizerPanel
			local node
			for _, n in pairs(build.spec.nodes) do
				if n.type == "Normal" then
					node = n
					break
				end
			end
			assert.is_not_nil(node, "should find a Normal node")

			panel.pinMode = false
			assert.is_false(panel:HandleNodeClick(node))

			panel.pinMode = true
			assert.is_true(panel:HandleNodeClick(node))
			assert.is_true(panel.pinnedNodes[node.id])

			assert.is_true(panel:HandleNodeClick(node)) -- second click unpins
			assert.is_nil(panel.pinnedNodes[node.id])
		end)
	end)
end)
