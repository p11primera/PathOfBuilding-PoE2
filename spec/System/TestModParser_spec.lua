describe("TestModParser", function()
	local band = AND64

	local function parseSingle(line)
		local modList, extra = modLib.parseMod(line)
		if modList and #modList >= 1 then
			return modList[1], extra
		end
		return nil, extra
	end

	local function assertFlag(flags, flag, msg)
		assert.are_not.equal(0, band(flags, flag), msg or "expected flag to be set")
	end

	---------------------------------------------------------------------------
	-- 1. Flat / BASE modifiers
	---------------------------------------------------------------------------
	describe("flat base modifiers", function()
		it("parses +N to maximum Life", function()
			local m = parseSingle("+50 to maximum Life")
			assert.is_truthy(m)
			assert.are.equal("Life", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(50, m.value)
		end)

		it("parses +N to Strength", function()
			local m = parseSingle("+10 to Strength")
			assert.is_truthy(m)
			assert.are.equal("Str", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(10, m.value)
		end)

		it("parses +N to Dexterity", function()
			local m = parseSingle("+10 to Dexterity")
			assert.is_truthy(m)
			assert.are.equal("Dex", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(10, m.value)
		end)

		it("parses +N to Intelligence", function()
			local m = parseSingle("+10 to Intelligence")
			assert.is_truthy(m)
			assert.are.equal("Int", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(10, m.value)
		end)

		it("parses +N to maximum Mana", function()
			local m = parseSingle("+50 to maximum Mana")
			assert.is_truthy(m)
			assert.are.equal("Mana", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(50, m.value)
		end)

		it("parses +N to maximum Energy Shield", function()
			local m = parseSingle("+100 to maximum Energy Shield")
			assert.is_truthy(m)
			assert.are.equal("EnergyShield", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(100, m.value)
		end)

		it("parses +N to Armour", function()
			local m = parseSingle("+500 to Armour")
			assert.is_truthy(m)
			assert.are.equal("Armour", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(500, m.value)
		end)

		it("parses +N% to Fire Resistance", function()
			local m = parseSingle("+30% to Fire Resistance")
			assert.is_truthy(m)
			assert.are.equal("FireResist", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(30, m.value)
		end)

		it("parses +N% to Cold Resistance", function()
			local m = parseSingle("+30% to Cold Resistance")
			assert.is_truthy(m)
			assert.are.equal("ColdResist", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(30, m.value)
		end)

		it("parses +N% to Lightning Resistance", function()
			local m = parseSingle("+30% to Lightning Resistance")
			assert.is_truthy(m)
			assert.are.equal("LightningResist", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(30, m.value)
		end)

		it("parses +N% to Chaos Resistance", function()
			local m = parseSingle("+20% to Chaos Resistance")
			assert.is_truthy(m)
			assert.are.equal("ChaosResist", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(20, m.value)
		end)

		it("parses +N% to all elemental resistances", function()
			local m = parseSingle("+15% to all Elemental Resistances")
			assert.is_truthy(m)
			assert.are.equal("ElementalResist", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(15, m.value)
		end)

		it("parses negative flat life", function()
			local m = parseSingle("-10 to maximum Life")
			assert.is_truthy(m)
			assert.are.equal("Life", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(-10, m.value)
		end)
	end)

	---------------------------------------------------------------------------
	-- 2. Increased / Reduced (INC) modifiers
	---------------------------------------------------------------------------
	describe("increased/reduced (INC) modifiers", function()
		it("parses N% increased maximum Life", function()
			local m = parseSingle("10% increased maximum Life")
			assert.is_truthy(m)
			assert.are.equal("Life", m.name)
			assert.are.equal("INC", m.type)
			assert.are.equal(10, m.value)
		end)

		it("parses N% reduced maximum Life (negative INC)", function()
			local m = parseSingle("10% reduced maximum Life")
			assert.is_truthy(m)
			assert.are.equal("Life", m.name)
			assert.are.equal("INC", m.type)
			assert.are.equal(-10, m.value)
		end)

		it("parses N% increased Physical Damage", function()
			local m = parseSingle("20% increased Physical Damage")
			assert.is_truthy(m)
			assert.are.equal("PhysicalDamage", m.name)
			assert.are.equal("INC", m.type)
			assert.are.equal(20, m.value)
		end)

		it("parses N% increased Attack Speed with Attack flag", function()
			local m = parseSingle("10% increased Attack Speed")
			assert.is_truthy(m)
			assert.are.equal("Speed", m.name)
			assert.are.equal("INC", m.type)
			assert.are.equal(10, m.value)
			assertFlag(m.flags, ModFlag.Attack, "expected Attack flag")
		end)

		it("parses N% increased Cast Speed with Cast flag", function()
			local m = parseSingle("10% increased Cast Speed")
			assert.is_truthy(m)
			assert.are.equal("Speed", m.name)
			assert.are.equal("INC", m.type)
			assert.are.equal(10, m.value)
			assertFlag(m.flags, ModFlag.Cast, "expected Cast flag")
		end)

		it("parses N% increased Spell Damage with Spell flag", function()
			local m = parseSingle("15% increased Spell Damage")
			assert.is_truthy(m)
			assert.are.equal("Damage", m.name)
			assert.are.equal("INC", m.type)
			assert.are.equal(15, m.value)
			assertFlag(m.flags, ModFlag.Spell, "expected Spell flag")
		end)

		it("parses N% increased Critical Hit Chance", function()
			local m = parseSingle("30% increased Critical Hit Chance")
			assert.is_truthy(m)
			assert.are.equal("CritChance", m.name)
			assert.are.equal("INC", m.type)
			assert.are.equal(30, m.value)
		end)

		it("parses N% increased Critical Damage Bonus", function()
			local m = parseSingle("25% increased Critical Damage Bonus")
			assert.is_truthy(m)
			assert.are.equal("CritMultiplier", m.name)
			assert.are.equal("INC", m.type)
			assert.are.equal(25, m.value)
		end)
	end)

	---------------------------------------------------------------------------
	-- 3. More / Less (MORE) modifiers
	---------------------------------------------------------------------------
	describe("more/less (MORE) modifiers", function()
		it("parses N% more Damage", function()
			local m = parseSingle("20% more Damage")
			assert.is_truthy(m)
			assert.are.equal("Damage", m.name)
			assert.are.equal("MORE", m.type)
			assert.are.equal(20, m.value)
		end)

		it("parses N% less Damage (negative MORE)", function()
			local m = parseSingle("20% less Damage")
			assert.is_truthy(m)
			assert.are.equal("Damage", m.name)
			assert.are.equal("MORE", m.type)
			assert.are.equal(-20, m.value)
		end)

		it("parses N% more Attack Speed with Attack flag", function()
			local m = parseSingle("10% more Attack Speed")
			assert.is_truthy(m)
			assert.are.equal("Speed", m.name)
			assert.are.equal("MORE", m.type)
			assert.are.equal(10, m.value)
			assertFlag(m.flags, ModFlag.Attack, "expected Attack flag")
		end)

		it("parses N% less damage taken", function()
			local m = parseSingle("50% less damage taken")
			assert.is_truthy(m)
			assert.are.equal("DamageTaken", m.name)
			assert.are.equal("MORE", m.type)
			assert.are.equal(-50, m.value)
		end)
	end)

	---------------------------------------------------------------------------
	-- 4. Added damage modifiers
	---------------------------------------------------------------------------
	describe("added damage modifiers", function()
		it("parses Adds N to N Physical Damage to Attacks", function()
			local modList = modLib.parseMod("Adds 10 to 20 Physical Damage to Attacks")
			assert.is_truthy(modList)
			assert.are.equal(2, #modList)

			local minMod, maxMod = modList[1], modList[2]
			assert.are.equal("PhysicalMin", minMod.name)
			assert.are.equal("BASE", minMod.type)
			assert.are.equal(10, minMod.value)
			assert.are.equal(KeywordFlag.Attack, minMod.keywordFlags)

			assert.are.equal("PhysicalMax", maxMod.name)
			assert.are.equal("BASE", maxMod.type)
			assert.are.equal(20, maxMod.value)
			assert.are.equal(KeywordFlag.Attack, maxMod.keywordFlags)
		end)

		it("parses Adds N to N Fire Damage", function()
			local modList = modLib.parseMod("Adds 5 to 10 Fire Damage")
			assert.is_truthy(modList)
			assert.are.equal(2, #modList)

			local minMod, maxMod = modList[1], modList[2]
			assert.are.equal("FireMin", minMod.name)
			assert.are.equal("BASE", minMod.type)
			assert.are.equal(5, minMod.value)

			assert.are.equal("FireMax", maxMod.name)
			assert.are.equal("BASE", maxMod.type)
			assert.are.equal(10, maxMod.value)
		end)
	end)

	---------------------------------------------------------------------------
	-- 5. Penetration modifiers
	---------------------------------------------------------------------------
	describe("penetration modifiers", function()
		it("parses Penetrates N% Fire Resistance", function()
			local m = parseSingle("Penetrates 10% Fire Resistance")
			assert.is_truthy(m)
			assert.are.equal("FirePenetration", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(10, m.value)
		end)

		it("parses Penetrates N% Elemental Resistances", function()
			local m = parseSingle("Penetrates 5% Elemental Resistances")
			assert.is_truthy(m)
			assert.are.equal("ElementalPenetration", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(5, m.value)
		end)
	end)

	---------------------------------------------------------------------------
	-- 6. Conditional modifiers (tags)
	---------------------------------------------------------------------------
	describe("conditional modifiers", function()
		it("parses per Power Charge with Multiplier tag", function()
			local m = parseSingle("10% increased Damage per Power Charge")
			assert.is_truthy(m)
			assert.are.equal("Damage", m.name)
			assert.are.equal("INC", m.type)
			assert.are.equal(10, m.value)
			-- First tag should be a Multiplier with var=PowerCharge
			local tag = m[1]
			assert.is_truthy(tag)
			assert.are.equal("Multiplier", tag.type)
			assert.are.equal("PowerCharge", tag.var)
		end)

		it("parses while Dual Wielding with Condition tag", function()
			local m = parseSingle("10% increased Attack Speed while Dual Wielding")
			assert.is_truthy(m)
			assert.are.equal("Speed", m.name)
			assert.are.equal("INC", m.type)
			assert.are.equal(10, m.value)
			assertFlag(m.flags, ModFlag.Attack, "expected Attack flag")
			-- First tag should be a Condition with var=DualWielding
			local tag = m[1]
			assert.is_truthy(tag)
			assert.are.equal("Condition", tag.type)
			assert.are.equal("DualWielding", tag.var)
		end)
	end)

	---------------------------------------------------------------------------
	-- 7. Damage conversion
	---------------------------------------------------------------------------
	describe("damage conversion", function()
		it("parses Physical Damage taken as Fire", function()
			local m = parseSingle("50% of Physical damage taken as Fire")
			assert.is_truthy(m)
			assert.are.equal("PhysicalDamageTakenAsFire", m.name)
			assert.are.equal("BASE", m.type)
			assert.are.equal(50, m.value)
		end)
	end)

	---------------------------------------------------------------------------
	-- 8. Flag / special modifiers
	---------------------------------------------------------------------------
	describe("flag and special modifiers", function()
		it("parses Chaos Inoculation as a keystone", function()
			local m = parseSingle("Chaos Inoculation")
			assert.is_truthy(m)
			assert.are.equal("Keystone", m.name)
			assert.are.equal("LIST", m.type)
			assert.are.equal("Chaos Inoculation", m.value)
		end)
	end)

	---------------------------------------------------------------------------
	-- 9. Unparseable
	---------------------------------------------------------------------------
	describe("unparseable input", function()
		it("returns nil for gibberish", function()
			local modList, extra = modLib.parseMod("xyzzy foobar baz")
			assert.is_nil(modList)
		end)
	end)
end)
