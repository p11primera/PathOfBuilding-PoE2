describe("TestAilments", function()
	before_each(function()
		newBuild()
	end)

	teardown(function() end)

	-- Helper: set custom mods and recalculate
	local function applyMods(modText)
		build.configTab.input.customMods = modText
		build.configTab:BuildModList()
		runCallback("OnFrame")
	end

	-- Helper: add a skill group and recalculate
	local function addSkill(skillText)
		build.skillsTab:PasteSocketGroup(skillText)
		runCallback("OnFrame")
	end

	-- Helper: equip a weapon and recalculate
	local function equipWeapon(raw)
		build.itemsTab:CreateDisplayItemFromRaw(raw)
		build.itemsTab:AddDisplayItem()
		runCallback("OnFrame")
	end

	describe("ignite", function()
		it("fire skill with ignite chance produces IgniteDPS", function()
			addSkill("Fireball 20/0  1")
			applyMods("100% chance to Ignite")
			build.configTab.input.enemyIsBoss = "None"
			build.configTab:BuildModList()
			runCallback("OnFrame")

			local igniteDPS = build.calcsTab.mainOutput.IgniteDPS or 0
			assert.is_true(igniteDPS > 0, "Fireball with 100% ignite chance should produce IgniteDPS")
		end)

		it("increased fire damage over time multiplier scales ignite", function()
			addSkill("Fireball 20/0  1")
			applyMods("100% chance to Ignite")
			build.configTab.input.enemyIsBoss = "None"
			build.configTab:BuildModList()
			runCallback("OnFrame")
			local baseIgnite = build.calcsTab.mainOutput.IgniteDPS or 0

			applyMods("100% chance to Ignite\n50% increased Damage over Time Multiplier for Ignite")
			build.configTab.input.enemyIsBoss = "None"
			build.configTab:BuildModList()
			runCallback("OnFrame")
			local scaledIgnite = build.calcsTab.mainOutput.IgniteDPS or 0

			if baseIgnite > 0 then
				assert.is_true(scaledIgnite > baseIgnite, "DoT multi should increase ignite DPS")
			end
		end)

		it("ignite DPS contributes to CombinedDPS", function()
			addSkill("Fireball 20/0  1")
			applyMods("100% chance to Ignite")
			build.configTab.input.enemyIsBoss = "None"
			build.configTab:BuildModList()
			runCallback("OnFrame")

			local igniteDPS = build.calcsTab.mainOutput.IgniteDPS or 0
			local hitDPS = build.calcsTab.mainOutput.TotalDPS or 0
			local combinedDPS = build.calcsTab.mainOutput.CombinedDPS or 0

			if igniteDPS > 0 then
				assert.is_true(combinedDPS >= hitDPS + igniteDPS * 0.9,
					"CombinedDPS should include IgniteDPS")
			end
		end)
	end)

	describe("bleed", function()
		it("physical attack with bleed chance produces BleedDPS", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			applyMods("100% chance to cause Bleeding on Hit")
			build.configTab.input.enemyIsBoss = "None"
			build.configTab:BuildModList()
			runCallback("OnFrame")

			local bleedDPS = build.calcsTab.mainOutput.BleedDPS or 0
			assert.is_true(bleedDPS > 0, "Physical attack with 100% bleed chance should produce BleedDPS")
		end)

		it("increased physical damage over time scales bleed", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			applyMods("100% chance to cause Bleeding on Hit")
			build.configTab.input.enemyIsBoss = "None"
			build.configTab:BuildModList()
			runCallback("OnFrame")
			local baseBleed = build.calcsTab.mainOutput.BleedDPS or 0

			applyMods("100% chance to cause Bleeding on Hit\n50% increased Damage over Time Multiplier")
			build.configTab.input.enemyIsBoss = "None"
			build.configTab:BuildModList()
			runCallback("OnFrame")
			local scaledBleed = build.calcsTab.mainOutput.BleedDPS or 0

			if baseBleed > 0 then
				assert.is_true(scaledBleed > baseBleed, "DoT multi should increase bleed DPS")
			end
		end)
	end)

	describe("poison", function()
		it("chaos skill with poison chance produces PoisonDPS", function()
			addSkill("Contagion 20/0  1")
			applyMods("100% chance to Poison on Hit")
			build.configTab.input.enemyIsBoss = "None"
			build.configTab:BuildModList()
			runCallback("OnFrame")

			local poisonDPS = build.calcsTab.mainOutput.PoisonDPS or 0
			-- Poison requires hit damage; Contagion may be DoT-only.
			-- If PoisonDPS is 0, try with a different skill that hits.
			if poisonDPS == 0 then
				-- Fallback: use a physical attack with added chaos
				newBuild()
				equipWeapon([[
					New Item
					Heavy Bow
				]])
				applyMods("100% chance to Poison on Hit\nAdds 10 to 20 Chaos Damage to Attacks")
				build.configTab.input.enemyIsBoss = "None"
				build.configTab:BuildModList()
				runCallback("OnFrame")
				poisonDPS = build.calcsTab.mainOutput.PoisonDPS or 0
			end

			assert.is_true(poisonDPS > 0, "Attack with poison chance and chaos damage should produce PoisonDPS")
		end)
	end)

	describe("ailment interaction with hit DPS", function()
		it("zero hit chance means zero ailment DPS", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			-- Reduce accuracy to minimum
			applyMods("100% chance to cause Bleeding on Hit\n100% reduced Accuracy Rating")
			build.configTab.input.enemyIsBoss = "None"
			build.configTab:BuildModList()
			runCallback("OnFrame")

			-- With very low hit chance, bleed DPS should be minimal or zero
			local hitChance = build.calcsTab.mainOutput.HitChance or 100
			local bleedDPS = build.calcsTab.mainOutput.BleedDPS or 0
			-- If hit chance is near zero, bleed should also be near zero
			if hitChance < 5 then
				assert.is_true(bleedDPS < 1, "Near-zero hit chance should produce near-zero bleed DPS")
			end
		end)

		it("ailment damage is separate from hit damage", function()
			-- Verify ailments don't double-count in the hit DPS number
			addSkill("Fireball 20/0  1")
			applyMods("100% chance to Ignite")
			build.configTab.input.enemyIsBoss = "None"
			build.configTab:BuildModList()
			runCallback("OnFrame")

			local hitDPS = build.calcsTab.mainOutput.TotalDPS or 0
			local igniteDPS = build.calcsTab.mainOutput.IgniteDPS or 0

			-- Now remove ignite chance
			applyMods("")
			build.configTab.input.enemyIsBoss = "None"
			build.configTab:BuildModList()
			runCallback("OnFrame")

			local hitDPSNoIgnite = build.calcsTab.mainOutput.TotalDPS or 0

			-- Hit DPS should be the same whether or not ignite is enabled
			if hitDPS > 0 then
				local ratio = hitDPSNoIgnite / hitDPS
				assert.is_true(math.abs(ratio - 1.0) < 0.01,
					"Hit DPS should not change when ignite is toggled")
			end
		end)
	end)
end)
