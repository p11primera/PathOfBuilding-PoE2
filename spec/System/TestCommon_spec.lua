describe("Common", function()
	describe("Class creation and use", function()
		it("produces error when parent constructors are not called", function()
			local ParentClass = newClass("ConstructorTestParentClass")
			function ParentClass:ConstructorTestParentClass()
				return self
			end
			local ChildClass = newClass("ConstructorTestProblemChild", "ConstructorTestParentClass")
			function ChildClass:ConstructorTestProblemChild()
				-- Intentionally does not call self:ConstructorTestParentClass()
				return self
			end
			common.classes.ConstructorTestParent = ParentClass
			common.classes.ConstructorTestProblemChild = ChildClass

			assert.has_error(function()
				new("ConstructorTestProblemChild"):ConstructorTestProblemChild()
			end, "Parent class 'ConstructorTestParentClass' of class 'ConstructorTestProblemChild' must be initialised")
			common.classes.ConstructorTestParent = nil
			common.classes.ConstructorTestProblemChild = nil
		end)
		it("produces an error if additional arguments are passed", function()
			local StupidClass = newClass("NewAbuse")
			function StupidClass:NewAbuse(someParam)
				return self
			end

			common.classes.NewAbuse = StupidClass

			assert.has_no.errors(function()
				local newObj = new("NewAbuse"):NewAbuse("fish")
			end)
			assert.has_error(function()
				local newObj = new("NewAbuse", "look I'm using the old syntax")
			end)
		end)
		it("produces an error if it calls a parent class without giving it self", function()
			local ParentClass = newClass("ConstructorTestParentClass")
			function ParentClass:ConstructorTestParentClass()
				return self
			end

			local ChildClass = newClass("ConstructorTestProblemChild", "ConstructorTestParentClass")
			function ChildClass:ConstructorTestProblemChild()
				self.ConstructorTestParentClass()
				return self
			end

			common.classes.ConstructorTestParent = ParentClass
			common.classes.ConstructorTestProblemChild = ChildClass

			assert.has_error(function()
				new("ConstructorTestProblemChild"):ConstructorTestProblemChild()
			end)
			common.classes.ConstructorTestParent = nil
			common.classes.ConstructorTestProblemChild = nil
		end)
		it("produces an error if its constructor doesn't return the object", function()
			local StupidClass = newClass("StupidClass")
			function StupidClass:StupidClass()
			end

			common.classes.StupidClass = StupidClass

			assert.has_error(function()
				new("StupidClass"):StupidClass()
			end, "Class StupidClass constructor did not return a value")
		end)
		-- disabled for performance reasons for now
		-- it("produces an error if its constructor has not been called", function()
		-- 	local StupidClass = newClass("StupidClass")
		-- 	function StupidClass:StupidClass()
		-- 		return self
		-- 	end

		-- 	function StupidClass:Clear()
		-- 	end

		-- 	common.classes.StupidClass = StupidClass

		-- 	assert.has_error(function()
		-- 		local object = new("StupidClass")
		-- 		return object.lines
		-- 	end)
		-- 	assert.has_error(function()
		-- 		local object = new("StupidClass")
		-- 		object:Clear()
		-- 	end)
		-- 	assert.has_no.errors(function()
		-- 		local object = new("StupidClass"):StupidClass()
		-- 		local x = object.lines
		-- 		object:Clear()
		-- 	end)
		-- 	common.classes.StupidClass = nil
		-- end)
	end)

	describe("copyTableSafe memo hygiene", function()
		-- Regression for the macOS "JIT wedge" (and Linux shard-2 OOM-flake):
		-- copyTableSafe's sub-table memo used to live in a module-level table
		-- wiped ONLY when the outermost copy ran to completion. Copies
		-- abandoned mid-copy (dropped coroutines, as the tree optimizer uses)
		-- or aborted by an error pinned every source sub-table and its mirror
		-- for the life of the process -- the heap grew to tens of GB until the
		-- memo write threw "table overflow" and the post-error full GC ground
		-- for minutes. The memo is now threaded per outermost call, so an
		-- unfinished copy must leave nothing reachable behind.
		local function wideTree(width)
			local t = { }
			for i = 1, width do
				t["k" .. i] = { id = i, deep = { a = i, b = { c = i } } }
			end
			return t
		end

		local function heapKB()
			collectgarbage("collect")
			collectgarbage("collect")
			return collectgarbage("count")
		end

		-- Old code leaked ~10-50 MB across these rounds; new code leaves only
		-- the test's own transient garbage (KB). 10 MB threshold is generous
		-- enough to never flake on GC jitter yet far below the leak size.
		local MAX_RESIDUE_KB = 10 * 1024

		it("leaves no residue when a copy is abandoned mid-copy (dropped coroutine)", function()
			local ITER, WIDTH = 60, 2000
			local before = heapKB()
			for _ = 1, ITER do
				local tree = wideTree(WIDTH)
				-- preserveMeta copies this metatable onto the output table, so
				-- __newindex suspends the outermost copy on its final write --
				-- by then every sub-table is memoised (mirrors the optimizer's
				-- resumable createOptimizerCoroutine being dropped after N steps).
				local seen = 0
				setmetatable(tree, { __newindex = function(obj, k, v)
					seen = seen + 1
					if seen >= WIDTH then
						coroutine.yield()
					end
					rawset(obj, k, v)
				end })
				local co = coroutine.create(function()
					return copyTableSafe(tree, false, true)
				end)
				coroutine.resume(co)
				-- is_true over assert.equals: keeps any failure message free of
				-- luassert tracebacks through this closure (see OOM note below)
				assert.is_true(coroutine.status(co) == "suspended",
					"expected the copy to be suspended mid-way, got " .. coroutine.status(co))
				-- abandon it: the optimizer does exactly this when a run is
				-- cancelled; both refs must die together with the per-call memo
				co, tree = nil, nil
			end
			local after = heapKB()
			assert.is_true(after - before < MAX_RESIDUE_KB,
				string.format("abandoned copies leaked %.0f KB of pinned tables", after - before))
		end)

		it("leaves no residue when a copy errors out", function()
			local ITER, WIDTH = 60, 5000
			local before = heapKB()
			for _ = 1, ITER do
				local tree = { }
				for i = 1, WIDTH do
					local child = { id = i, deep = { a = i } }
					-- getmetatable(child) returns a string, so setmetatable on
					-- the child's mirror throws AFTER the child was memoised --
					-- the copy dies with state in the memo.
					setmetatable(child, { __metatable = "locked" })
					tree["k" .. i] = child
				end
				-- pcall, not assert.has_error: luassert materialises a traceback
				-- through the test closure (this one holds a 5000-key tree) and
				-- OOM-killed a shard once before.
				local ok = pcall(copyTableSafe, tree, false, true)
				assert.is_true(not ok, "copy was expected to error mid-way")
				tree = nil
			end
			local after = heapKB()
			assert.is_true(after - before < MAX_RESIDUE_KB,
				string.format("errored copies leaked %.0f KB of pinned tables", after - before))
		end)

		it("still shares one mirror per identical sub-table within a copy", function()
			-- memo semantics must be preserved: the same sub-table appearing
			-- twice must map to the SAME mirror table.
			local shared = { v = 1 }
			local copy = copyTableSafe({ a = shared, b = shared }, false, true)
			assert.equals(copy.a, copy.b)
			assert.not_equals(shared, copy.a)
		end)
	end)
end)
