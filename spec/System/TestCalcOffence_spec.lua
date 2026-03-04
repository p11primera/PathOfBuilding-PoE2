describe("TestCalcOffence", function()
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

	-- Helper: equip a weapon and recalculate
	local function equipWeapon(raw)
		build.itemsTab:CreateDisplayItemFromRaw(raw)
		build.itemsTab:AddDisplayItem()
		runCallback("OnFrame")
	end

	-- Helper: add a skill group and recalculate
	local function addSkill(skillText)
		build.skillsTab:PasteSocketGroup(skillText)
		runCallback("OnFrame")
	end

	describe("base unarmed damage", function()
		it("has non-zero DPS with default unarmed attack", function()
			-- Default Scion build should have some base unarmed DPS
			assert.is_true(build.calcsTab.mainOutput.TotalDPS > 0)
		end)

		it("has correct unarmed crit chance", function()
			local expectedCrit = data.unarmedWeaponData[0].CritChance * build.calcsTab.mainOutput.HitChance / 100
			assert.are.equals(expectedCrit, build.calcsTab.mainOutput.CritChance)
		end)

		it("has base crit multiplier of 2x", function()
			assert.are.equals(2, build.calcsTab.mainOutput.CritMultiplier)
		end)
	end)

	describe("weapon equip affects DPS", function()
		it("equipping a bow changes attack speed and base damage", function()
			local unarmedDPS = build.calcsTab.mainOutput.TotalDPS

			equipWeapon([[
				New Item
				Heavy Bow
			]])

			-- DPS should change when equipping a weapon
			assert.are_not.equals(unarmedDPS, build.calcsTab.mainOutput.TotalDPS)
		end)

		it("weapon with added damage increases DPS", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			local baseDPS = build.calcsTab.mainOutput.TotalDPS

			-- Create a new build with a better weapon
			newBuild()
			equipWeapon([[
				New Item
				Heavy Bow
				Adds 10 to 20 Physical Damage
			]])
			local boostedDPS = build.calcsTab.mainOutput.TotalDPS

			assert.is_true(boostedDPS > baseDPS)
		end)
	end)

	describe("increased damage scaling", function()
		it("increased physical damage scales DPS", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			local baseDPS = build.calcsTab.mainOutput.TotalDPS

			applyMods("100% increased Physical Damage")
			local scaledDPS = build.calcsTab.mainOutput.TotalDPS

			-- 100% increased should roughly double the physical portion
			assert.is_true(scaledDPS > baseDPS)
		end)

		it("increased attack speed scales DPS", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			local baseDPS = build.calcsTab.mainOutput.TotalDPS
			local baseSpeed = build.calcsTab.mainOutput.Speed

			applyMods("50% increased Attack Speed")
			local scaledDPS = build.calcsTab.mainOutput.TotalDPS
			local scaledSpeed = build.calcsTab.mainOutput.Speed

			assert.is_true(scaledSpeed > baseSpeed)
			assert.is_true(scaledDPS > baseDPS)
		end)
	end)

	describe("more damage multipliers", function()
		it("more damage multiplies DPS", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			local baseDPS = build.calcsTab.mainOutput.TotalDPS

			applyMods("50% more Damage")
			local scaledDPS = build.calcsTab.mainOutput.TotalDPS

			-- 50% more should multiply DPS by 1.5
			local ratio = scaledDPS / baseDPS
			assert.is_true(math.abs(ratio - 1.5) < 0.01)
		end)

		it("multiple more multipliers stack multiplicatively", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			local baseDPS = build.calcsTab.mainOutput.TotalDPS

			applyMods("50% more Damage\n50% more Damage")
			local scaledDPS = build.calcsTab.mainOutput.TotalDPS

			-- Two 50% more = 1.5 * 1.5 = 2.25x
			local ratio = scaledDPS / baseDPS
			assert.is_true(math.abs(ratio - 2.25) < 0.01)
		end)

		it("less damage reduces DPS", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			local baseDPS = build.calcsTab.mainOutput.TotalDPS

			applyMods("50% less Damage")
			local scaledDPS = build.calcsTab.mainOutput.TotalDPS

			local ratio = scaledDPS / baseDPS
			assert.is_true(math.abs(ratio - 0.5) < 0.01)
		end)
	end)

	describe("crit calculations", function()
		it("increased crit chance raises crit rate", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			local baseCrit = build.calcsTab.mainOutput.CritChance

			applyMods("100% increased Critical Hit Chance")
			local scaledCrit = build.calcsTab.mainOutput.CritChance

			assert.is_true(scaledCrit > baseCrit)
		end)

		it("crit chance caps at 100%", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])

			applyMods("10000% increased Critical Hit Chance")
			local maxCrit = build.calcsTab.mainOutput.CritChance

			assert.is_true(maxCrit <= 100)
		end)

		it("increased crit multiplier increases average damage", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			applyMods("500% increased Critical Hit Chance")
			local baseAvg = build.calcsTab.mainOutput.AverageHit or build.calcsTab.mainOutput.AverageDamage

			newBuild()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			applyMods("500% increased Critical Hit Chance\n100% increased Critical Damage Bonus")
			local boostedAvg = build.calcsTab.mainOutput.AverageHit or build.calcsTab.mainOutput.AverageDamage

			assert.is_true(boostedAvg > baseAvg)
		end)
	end)

	describe("spell damage", function()
		it("spell skill produces DPS", function()
			addSkill("Fireball 1/0  1")
			assert.is_true(build.calcsTab.mainOutput.TotalDPS > 0)
		end)

		it("increased spell damage scales spell DPS", function()
			addSkill("Fireball 1/0  1")
			local baseDPS = build.calcsTab.mainOutput.TotalDPS

			applyMods("100% increased Spell Damage")
			local scaledDPS = build.calcsTab.mainOutput.TotalDPS

			assert.is_true(scaledDPS > baseDPS)
		end)

		it("increased fire damage scales fireball", function()
			addSkill("Fireball 1/0  1")
			local baseDPS = build.calcsTab.mainOutput.TotalDPS

			applyMods("100% increased Fire Damage")
			local scaledDPS = build.calcsTab.mainOutput.TotalDPS

			assert.is_true(scaledDPS > baseDPS)
		end)

		it("increased cold damage does not scale fireball", function()
			addSkill("Fireball 1/0  1")
			local baseDPS = build.calcsTab.mainOutput.TotalDPS

			applyMods("100% increased Cold Damage")
			local scaledDPS = build.calcsTab.mainOutput.TotalDPS

			assert.are.equals(baseDPS, scaledDPS)
		end)
	end)

	describe("damage conversion", function()
		it("physical to fire conversion with fire scaling", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			applyMods("50% of Physical Damage Converted to Fire Damage")
			local convertedDPS = build.calcsTab.mainOutput.TotalDPS

			-- Adding fire damage scaling should now matter
			newBuild()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			applyMods("50% of Physical Damage Converted to Fire Damage\n100% increased Fire Damage")
			local scaledDPS = build.calcsTab.mainOutput.TotalDPS

			assert.is_true(scaledDPS > convertedDPS)
		end)
	end)

	describe("penetration", function()
		it("fire penetration increases damage against resistant enemies", function()
			addSkill("Fireball 1/0  1")
			build.configTab.input.enemyFireResist = 50
			build.configTab:BuildModList()
			runCallback("OnFrame")
			local baseDPS = build.calcsTab.mainOutput.TotalDPS

			applyMods("Penetrates 20% Fire Resistance")
			build.configTab.input.enemyFireResist = 50
			build.configTab:BuildModList()
			runCallback("OnFrame")
			local penDPS = build.calcsTab.mainOutput.TotalDPS

			assert.is_true(penDPS > baseDPS)
		end)
	end)

	describe("DPS formula integrity", function()
		it("TotalDPS equals AverageDamage times Speed", function()
			equipWeapon([[
				New Item
				Heavy Bow
			]])
			applyMods("100% increased Physical Damage\n50% increased Attack Speed")

			local avgDmg = build.calcsTab.mainOutput.AverageDamage
			local speed = build.calcsTab.mainOutput.Speed
			local totalDPS = build.calcsTab.mainOutput.TotalDPS

			-- TotalDPS = AverageDamage * Speed * dpsMultiplier
			-- For basic attacks, dpsMultiplier should be 1
			if avgDmg and speed and totalDPS and avgDmg > 0 then
				local expected = avgDmg * speed
				local ratio = totalDPS / expected
				assert.is_true(math.abs(ratio - 1.0) < 0.05,
					string.format("DPS formula mismatch: TotalDPS=%f, AvgDmg*Speed=%f", totalDPS, expected))
			end
		end)
	end)
end)
