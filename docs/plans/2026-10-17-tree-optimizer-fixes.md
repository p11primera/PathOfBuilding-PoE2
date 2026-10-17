# Tree Optimizer Fix Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Make the passive-tree auto-optimizer actually start, score candidates correctly, respect pins/budget, stop when converged, and leave the tree in a valid state — per the original design doc (`docs/plans/2026-02-27-tree-optimizer-design.md`).

**Architecture:** Three fix layers: (A) startup crashes — upstream's `new()` API and Build construction order now invalidate the optimizer UI classes; (B) SA core correctness — candidate scoring double-counts allocations, swap can desync spec/score, pins ignored in sync path, early stop unreachable; (C) state/restore + UI gaps — bypassing PassiveSpec API loses mastery state, error path leaves a mutated tree, no unpin controls. The two duplicated SA loops (sync + coroutine) are unified into one shared state machine so fixes land once.

**Tech Stack:** Lua (LuaJIT, PoB2 codebase), busted spec tests (`spec/System/`), GitHub Actions via `gh` CLI.

**Repo:** `~/workspace/poe2-assessment/PathOfBuilding-PoE2`, working branch `auto-optimizer-rebase` (pushes to remote `feature/auto-optimizer`).
**Push:** `git push origin auto-optimizer-rebase:feature/auto-optimizer --force-with-lease` (backup branch `backup/auto-optimizer-pre-rebase` already exists).
**CI gotcha (bit us before):** every `gh run`/`gh workflow` command MUST include `--repo p11primera/PathOfBuilding-PoE2` or it 404s against upstream.

---

## Dependency Map

```
Task 1 (TreeTab new-style) ─┐
Task 2 (Panel new-style)   ─┼─→ Phase A done → smoke: app opens a build
Task 3 (PVT self.build)    ─┘
Task 4 (shared SA state machine) ←─ prerequisite for Tasks 5–8 (all edit the unified loop)
Task 5 (scoring) ─┐
Task 6 (mutation invariants) ─┼─→ Task 9 (snapshot/restore via API) → Task 10 (panel behavior)
Task 7 (pins+budget) ─┤
Task 8 (early stop/tuning) ─┘
Task 11 (test hardening) ←─ after 4–8; Task 12 (UI smoke spec) ←─ after 1–3, 10
Task 13 (CI green) ←─ all
```

Execute sequentially 1→13. Tasks 1–3 are independent of each other.

---

## Phase A — Startup crashes (the "dead on arrival" layer)

Background: upstream commit bumped `new(className)` in `src/Modules/Common.lua:185-195` to **throw** on any extra argument ("Extra argument passed to new()... Are you perhaps trying to pass constructor arguments here?"). The repo-wide pattern is now `new("X"):X(args...)`. The optimizer UI was written pre-rebase with `new("X", ctorArgs)` and references `self.build` where none exists.

### Task 1: Convert TreeTab optimizer controls to new-style construction

**Objective:** Stop `TreeTabClass:TreeTab` from throwing when any build opens.

**Files:**
- Modify: `src/Classes/TreeTab.lua:286-298` (the "Optimizer Button" / "Optimizer Panel" block)

**Step 1: Replace the block** — current code (throws) is:

```lua
	-- Optimizer Button
	self.controls.optimizerToggle = new("ButtonControl", { "LEFT", self.controls.powerReport, "RIGHT" }, { 8, 0, 150, 20 },
		function() return self.controls.optimizerPanel.shown and "Hide Optimizer" or "Show Optimizer" end,
		function()
			self.controls.optimizerPanel.shown = not self.controls.optimizerPanel.shown
		end)

	-- Optimizer Panel
	self.controls.optimizerPanel = new("OptimizerPanel",
		{ "TOPLEFT", self.controls.specSelect, "BOTTOMLEFT" },
		{ 0, 4, 700, 120 },
```

Replace with (same-name method call style, matching `TreeTab.lua:145`'s `new("ButtonControl"):ButtonControl(...)`):

```lua
	-- Optimizer Button
	self.controls.optimizerToggle = new("ButtonControl"):ButtonControl({ "LEFT", self.controls.powerReport, "RIGHT" }, { 8, 0, 150, 20 },
		function() return self.controls.optimizerPanel.shown and "Hide Optimizer" or "Show Optimizer" end,
		function()
			self.controls.optimizerPanel.shown = not self.controls.optimizerPanel.shown
		end)

	-- Optimizer Panel
	self.controls.optimizerPanel = new("OptimizerPanel"):OptimizerPanel(
		{ "TOPLEFT", self.controls.specSelect, "BOTTOMLEFT" },
		{ 0, 4, 700, 120 },
		self.build)
	self.controls.optimizerPanel.shown = false
```

NOTE: check the tail of the existing block — if the original already passes `self.build` as the last constructor arg and sets `shown = false` after, preserve that; the two lines above just add what's missing.

**Step 2: Verify** — `luajit -bl` is unavailable locally; static check instead:

```bash
grep -n 'new("[A-Za-z]*Control",' src/Classes/TreeTab.lua   # expect: no matches (all must be new("X"):X( )
```

**Step 3: Commit**

```bash
git add src/Classes/TreeTab.lua
git commit -m "fix(optimizer): use new-style control construction in TreeTab (upstream new() guard)"
```

### Task 2: Rewrite OptimizerPanel control creation + lazy optimizer handle

**Objective:** Panel no longer (a) trips the `new()` guard on every control it creates, (b) dereferences `build.calcsTab` in its constructor — `Build.lua:528` creates `treeTab` BEFORE `calcsTab` (line 530), and `CompareEntry.lua:115/117` has the same order.

**Files:**
- Modify: `src/Classes/OptimizerPanel.lua` (constructor lines 13-95 and every `new(` use)

**Step 1: First confirm each control's same-name method signature** (signatures confirmed in the audit but re-verify cheaply):

```bash
grep -n "^function ButtonClass:\|^function LabelClass:\|^function SliderClass:\|^function EditClass:\|^function DropDownClass:" src/Classes/{ButtonControl,LabelControl,SliderControl,EditControl,DropDownControl}.lua
```

Expected methods (same name as class): `ButtonControl(anchor, rect, label, onClick)`, `LabelControl(anchor, rect, label)`, `SliderControl(anchor, rect, changeFunc)`, `EditControl(anchor, rect, text, prompt, pattern, maxLength, changeFunc)` (changeFunc is the 7th positional arg), `DropDownControl(anchor, rect, list, changeFunc)`.

**Step 2: Delete constructor line 17** (`self.optimizer = build.calcsTab.calcs.optimizer`) and add a lazy getter after the constructor:

```lua
function OptimizerPanelClass:GetOptimizer()
	if not self.optimizer then
		local calcsTab = self.build.calcsTab
		self.optimizer = calcsTab and calcsTab.calcs and calcsTab.calcs.optimizer
	end
	return self.optimizer
end
```

**Step 3: Convert EVERY control creation.** All ~12 occurrences of `new("X", anchor, rect, ...)` become `new("X"):X(anchor, rect, ...)`, args unchanged. Full replacement for the constructor control block (lines 31-91):

```lua
	-- Offence/Defence priority slider
	self.controls.alphaLabel = new("LabelControl"):LabelControl({ "TOPLEFT", self, "TOPLEFT" }, { 10, 8, 0, 16 }, "Defence")
	self.controls.alphaSlider = new("SliderControl"):SliderControl({ "LEFT", self.controls.alphaLabel, "RIGHT" }, { 8, 0, 150, 16 }, function(val)
		self.alpha = val
	end)
	self.controls.alphaSlider:SetVal(0.5)
	self.controls.alphaLabelR = new("LabelControl"):LabelControl({ "LEFT", self.controls.alphaSlider, "RIGHT" }, { 8, 0, 0, 16 }, "Offence")

	-- Point budget
	self.controls.budgetLabel = new("LabelControl"):LabelControl({ "LEFT", self.controls.alphaLabelR, "RIGHT" }, { 20, 0, 0, 16 }, "Points:")
	self.controls.budgetEdit = new("EditControl"):EditControl({ "LEFT", self.controls.budgetLabel, "RIGHT" }, { 4, 0, 50, 18 }, "", nil, "%D", 3, function(buf)
		self.pointBudget = tonumber(buf) or 0
	end)

	-- Pin mode toggle
	self.controls.pinModeBtn = new("ButtonControl"):ButtonControl({ "LEFT", self.controls.budgetEdit, "RIGHT" }, { 12, 0, 100, 18 },
		function() return self.pinMode and "Pin Mode: ON" or "Pin Mode: OFF" end,
		function()
			self.pinMode = not self.pinMode
		end)

	-- Start/Stop button
	self.controls.startBtn = new("ButtonControl"):ButtonControl({ "LEFT", self.controls.pinModeBtn, "RIGHT" }, { 12, 0, 80, 18 },
		function() return self.running and "Stop" or "Start" end,
		function()
			if self.running then
				self:StopOptimizer()
			else
				self:StartOptimizer()
			end
		end)

	-- Progress label
	self.controls.progressLabel = new("LabelControl"):LabelControl({ "LEFT", self.controls.startBtn, "RIGHT" }, { 12, 0, 0, 16 }, "")

	-- Second row: Pinned nodes search
	self.controls.pinSearchLabel = new("LabelControl"):LabelControl({ "TOPLEFT", self, "TOPLEFT" }, { 10, 32, 0, 16 }, "Pin Node:")
	self.controls.pinSearch = new("EditControl"):EditControl({ "LEFT", self.controls.pinSearchLabel, "RIGHT" }, { 4, 0, 200, 18 }, "", "Search...", nil, nil, function(buf)
		self:UpdateSearchResults(buf)
	end)
	self.controls.pinSearchResults = new("DropDownControl"):DropDownControl({ "LEFT", self.controls.pinSearch, "RIGHT" }, { 4, 0, 200, 18 }, { }, function(index, value)
		if value and value.id then
			self:PinNode(value.id, value.name, value.type)
			self.controls.pinSearch:SetText("")
		end
	end)

	-- Pinned nodes count label
	self.controls.pinnedLabel = new("LabelControl"):LabelControl({ "LEFT", self.controls.pinSearchResults, "RIGHT" }, { 12, 0, 0, 16 },
		function() return "Pinned: " .. #self.pinnedNodesList end)

	-- Apply / Reset buttons (row 3, shown after optimization)
	self.controls.applyBtn = new("ButtonControl"):ButtonControl({ "TOPLEFT", self, "TOPLEFT" }, { 10, 56, 120, 18 }, "Apply Best Tree", function()
		self:ApplyBestTree()
	end)
	self.controls.applyBtn.shown = function() return self.bestResult ~= nil end

	self.controls.resetBtn = new("ButtonControl"):ButtonControl({ "LEFT", self.controls.applyBtn, "RIGHT" }, { 8, 0, 120, 18 }, "Reset to Original", function()
		self:ResetToOriginal()
	end)
	self.controls.resetBtn.shown = function() return self.originalAlloc ~= nil end
```

**Step 4: Route the two optimizer users through the getter** — in `UpdateSearchResults` (`self.optimizer.findNodesByName` → `self:GetOptimizer().findNodesByName`) and in `StartOptimizer` (see Task 10, which rewrites it anyway).

**Step 5: Verify**

```bash
grep -n 'new("[A-Za-z]*Control",' src/Classes/OptimizerPanel.lua   # expect no matches
grep -n 'calcsTab' src/Classes/OptimizerPanel.lua                  # expect only inside GetOptimizer
```

**Step 6: Commit** `git commit -am "fix(optimizer): new-style controls + lazy calcsTab access in OptimizerPanel"`

### Task 3: Fix nil `self.build` in PassiveTreeView optimizer hooks

**Objective:** Both optimizer insertions (click intercept, pin ring) reference `self.build`, which PassiveTreeViewClass never assigns — every node click and every draw frame throws.

**Files:**
- Modify: `src/Classes/PassiveTreeView.lua:428-429` and `:1230-1231`

**Step 1:** Both sites sit inside `PassiveTreeViewClass:Draw(build, viewPort, inputEvents)` (starts line 172) — the `build` local is in scope. Replace `self.build.treeTab.controls.optimizerPanel` with `build.treeTab.controls.optimizerPanel` at both sites (2 lines × 2 sites = 4 occurrences; `grep -n "self.build" src/Classes/PassiveTreeView.lua` must return zero matches afterwards — these were the only uses in the file).

**Step 2: Verify + commit**

```bash
grep -c "self.build" src/Classes/PassiveTreeView.lua  # expect 0
git commit -am "fix(optimizer): PassiveTreeView uses Draw's build param, not nonexistent self.build"
```

**Phase A acceptance:** `new("Build")` path no longer throws at optimizer lines. Real proof comes in Task 12's UI smoke spec; interim check is the greps above + Phase-D CI.

---

## Phase B — SA core correctness

All edits are in `src/Modules/TreeOptimizer.lua`. Tasks 5-8 modify the unified loop created in Task 4 — do NOT touch the old duplicated loops.

### Task 4: Unify runSA + coroutine into a shared SA state machine

**Objective:** The two ~80-line SA copies have already diverged (coroutine pins, runSA doesn't). Extract state init + single step; runSA and the coroutine become thin drivers. Behavior-neutral refactor.

**Files:**
- Modify: `src/Modules/TreeOptimizer.lua` — replace `runSA` (lines 199-281) and `createOptimizerCoroutine` (lines 315-414) with the code below. `evaluateAlloc` stays for now (removed in Task 5).

**Step 1: Add shared state + step** (also change `calcScore` to return its components — existing callers ignore extras):

```lua
function optimizer.calcScore(output, baseOutput, alpha, customWeights)
	-- (body unchanged for now; see Task 5 for scoring rewrite)
	local baseDPS = m_max(1, baseOutput.CombinedDPS or 0)
	local offenceRatio = (output.CombinedDPS or 0) / baseDPS
	local baseDefence = m_max(0.001, optimizer.calcDefenceMetric(baseOutput, customWeights))
	local defenceRatio = optimizer.calcDefenceMetric(output, customWeights) / baseDefence
	return alpha * offenceRatio + (1 - alpha) * defenceRatio, offenceRatio, defenceRatio
end

local SA_DEFAULTS = {
	initialTemp = 1.0,
	coolingRate = 0.9997,
	reheatFactor = 0.5,
	maxStagnant = 500,
	earlyStopStagnant = 2000,
	maxReheats = 3,
	maxIterations = 10000,
	pointBudget = 50,
	alpha = 0.5,
}

function optimizer.initSAState(build, params)
	params = params or { }
	local state = { }
	local function opt(key) return params[key] or SA_DEFAULTS[key] end
	state.alpha = opt("alpha")
	state.maxIter = opt("maxIterations")
	state.budget = opt("pointBudget")
	state.pinned = params.pinnedNodes or { }
	state.weights = params.customWeights
	state.T0 = opt("initialTemp")
	state.coolingRate = opt("coolingRate")
	state.reheatFactor = opt("reheatFactor")
	state.maxStagnant = opt("maxStagnant")
	state.earlyStopStagnant = opt("earlyStopStagnant")
	state.maxReheats = opt("maxReheats")
	state.spec = build.spec
	state.temp = state.T0
	state.stagnantCount = 0
	state.reheats = 0
	state.evalCount = 0
	if params.seed then m_randomseed(params.seed) end
	local calcFunc, calcBase = build.calcsTab:GetMiscCalculator()
	state.calcFunc = calcFunc
	state.calcBase = calcBase
	local score, offence, defence = optimizer.calcScore(calcBase, calcBase, state.alpha, state.weights)
	state.currentAlloc = optimizer.snapshotAlloc(state.spec)
	state.currentScore = score
	state.bestAlloc = optimizer.snapshotAlloc(state.spec)
	state.bestScore = score
	state.bestOffence = offence
	state.bestDefence = defence
	return state
end

-- One SA iteration. Returns "ok" or "earlystop".
function optimizer.saStep(state)
	local spec = state.spec
	local prevAlloc = optimizer.snapshotAlloc(spec)
	local mutated = optimizer.mutate(spec, state.pinned)
	if mutated then
		trimToBudget(spec, state.pinned, state.budget)
		local output = evaluateAlloc(state.calcFunc, spec)
		state.evalCount = state.evalCount + 1
		local newScore, offence, defence = optimizer.calcScore(output, state.calcBase, state.alpha, state.weights)
		local prob = optimizer.acceptanceProbability(state.currentScore, newScore, state.temp)
		if m_random() < prob then
			state.currentAlloc = optimizer.snapshotAlloc(spec)
			state.currentScore = newScore
			if newScore > state.bestScore then
				state.bestAlloc = optimizer.snapshotAlloc(spec)
				state.bestScore = newScore
				state.bestOffence = offence
				state.bestDefence = defence
				state.stagnantCount = 0
			else
				state.stagnantCount = state.stagnantCount + 1
			end
		else
			optimizer.restoreAlloc(spec, prevAlloc)
			state.stagnantCount = state.stagnantCount + 1
		end
	else
		state.stagnantCount = state.stagnantCount + 1
	end
	state.temp = state.temp * state.coolingRate
	if state.stagnantCount >= state.earlyStopStagnant then
		return "earlystop"
	end
	if state.stagnantCount >= state.maxStagnant and state.reheats < state.maxReheats then
		state.temp = state.T0 * state.reheatFactor
		state.reheats = state.reheats + 1
	end
	return "ok"
end

function optimizer.saResult(state, iter)
	return {
		bestAlloc = state.bestAlloc,
		bestScore = state.bestScore,
		bestOffence = state.bestOffence,
		bestDefence = state.bestDefence,
		iterations = iter,
		evalCount = state.evalCount,
	}
end
```

Add `local m_randomseed = math.randomseed` to the locals block at the top.

**Step 2: Thin drivers** (replace both old loops; `ensurePinnedAllocated` call is added in Task 7):

```lua
function optimizer.runSA(build, params)
	local state = optimizer.initSAState(build, params)
	for iter = 1, state.maxIter do
		if optimizer.saStep(state) == "earlystop" then
			optimizer.restoreAlloc(state.spec, state.bestAlloc)
			return optimizer.saResult(state, iter)
		end
	end
	optimizer.restoreAlloc(state.spec, state.bestAlloc)
	return optimizer.saResult(state, state.maxIter)
end

function optimizer.createOptimizerCoroutine(build, params)
	return coroutine.create(function()
		local state = optimizer.initSAState(build, params)
		local start = GetTime and GetTime() or os.clock() * 1000
		for iter = 1, state.maxIter do
			if optimizer.saStep(state) == "earlystop" then
				optimizer.restoreAlloc(state.spec, state.bestAlloc)
				return optimizer.saResult(state, iter)
			end
			-- Yield every ~100ms for UI responsiveness
			local now = GetTime and GetTime() or os.clock() * 1000
			if now - start > 100 then
				coroutine.yield({
					progress = iter / state.maxIter,
					iteration = iter,
					bestScore = state.bestScore,
				})
				start = now
			end
		end
		optimizer.restoreAlloc(state.spec, state.bestAlloc)
		return optimizer.saResult(state, state.maxIter)
	end)
end
```

**Step 3: Verify** — `luajit -bl src/Modules/TreeOptimizer.lua` if available, else `grep -c "stagnantCount = 0" src/Modules/TreeOptimizer.lua` must be 1 (only on new-best, never on reheat), and `grep -c "for iter = 1" ` must be 2 (the two drivers). Run existing spec expectations mentally: `runSA` still returns `bestAlloc/bestScore/iterations` (superset OK).

**Step 4: Commit** `git commit -am "refactor(optimizer): unify SA loops into shared initSAState/saStep"`

### Task 5: Fix candidate scoring (the double-count bug)

**Objective:** `evaluateAlloc` passed the ENTIRE allocation as `override.addNodes`, but `calcFunc` overrides are **diffs applied on top of the live spec** (`CalcSetup.lua:1084-1109` increments `allocatedNotableCount`/`allocatedMasteryCount` per addNode) — every candidate scored with ~2× notable/mastery counts vs a 1× baseline, so SA optimized a phantom. Also: base and candidate must be computed by the same code path, use FullDPS when available (design doc §Scoring), and survive a zero-DPS seed without letting offence swamp defence.

**Files:**
- Modify: `src/Modules/TreeOptimizer.lua` — `evaluateAlloc` (lines 188-197) and `calcScore`

**Step 1: Replace `evaluateAlloc`** — mutations already mutate `build.spec` live, so candidates need NO override (empty diff = score the live tree, same code path as base):

```lua
-- Evaluate the CURRENT live tree via a full recalc (empty override diff —
-- calcFunc overrides are applied ON TOP of the live spec, so passing the
-- already-allocated set would double-count notable/mastery modifiers).
-- useFullDPS = true matches the design doc (sustained DPS).
local function evaluateAlloc(calcFunc, spec)
	return calcFunc({ }, true)
end
```

**Step 2: Compute the base with the same call.** In `initSAState`, replace the `calcFunc, calcBase = build.calcsTab:GetMiscCalculator()` line:

```lua
	local calcFunc = build.calcsTab:GetMiscCalculator()
	state.calcFunc = calcFunc
	state.calcBase = calcFunc({ }, true)
```

**Step 3: Rewrite `calcScore`** — FullDPS preference + safe ratios for zero baselines (current `m_max(1, baseDPS)` makes offence raw-DPS on fresh builds, so the alpha slider is numerically dead; and `baseDefence` clamped to 0.001 lets defence explode):

```lua
-- Candidate/base ratio that degrades gracefully when base == 0:
-- relative improvement when possible, bounded absolute term when not.
local function safeRatio(candidate, base, scale)
	if base > 0 then
		return candidate / base
	end
	return candidate / (candidate + scale)   -- in [0, 1) when base is 0
end

local DPS_SCALE = 1000    -- reference DPS for zero-base normalisation
local DEFENCE_SCALE = 1   -- defence metric is already O(1)-normalised

local function getDPS(output)
	local fullDPS = output.FullDPS
	if fullDPS and fullDPS > 0 then
		return fullDPS
	end
	return output.CombinedDPS or 0
end

function optimizer.calcScore(output, baseOutput, alpha, customWeights)
	local offenceRatio = safeRatio(getDPS(output), getDPS(baseOutput), DPS_SCALE)
	local defenceRatio = safeRatio(
		optimizer.calcDefenceMetric(output, customWeights),
		optimizer.calcDefenceMetric(baseOutput, customWeights),
		DEFENCE_SCALE)
	return alpha * offenceRatio + (1 - alpha) * defenceRatio, offenceRatio, defenceRatio
end
```

**Step 4: Fix the ES term truthiness bug** in `calcDefenceMetric` line 29 (in Lua `0` is truthy, so a present-but-zero `EnergyShieldRecoveryCap` shadows real `EnergyShield`):

```lua
	local es = output.EnergyShieldRecoveryCap
	if not es or es == 0 then
		es = output.EnergyShield or 0
	end
	-- then use  (w.EnergyShield or 0) * es / 3000
```

**Step 5: Sanity check `calcFunc({ }, true)` is legal** — open `src/Classes/CalcsTab.lua`, find where `miscCalculator[1]` is built; confirm the closure tolerates an empty override table (PowerBuilder calls `calcFunc({ addNodes = { [node] = true } }, useFullDPS)` at CalcsTab.lua:625, so the (table, bool) form is proven; an empty diff must simply add nothing).

**Step 6: Commit** `git commit -am "fix(optimizer): score candidates without double-counting; FullDPS-aware and zero-base-safe scoring"`

### Task 6: Mutation invariants (swap desync, no-op adds, dead path-shift)

**Objective:** (a) `mutateSwap` could leave the spec mutated while returning false → `saStep` kept a stale `currentScore` for the whole rest of the run. (b) `mutateAdd` returned true even when `AllocNode` silently no-op'd (missing `node.path`). (c) The 10% "Path Shift" operator was a literal alias of Swap — wasted budget.

**Files:**
- Modify: `src/Modules/TreeOptimizer.lua:113-155`

**Step 1: Replace the three operators + `mutate`:**

```lua
-- Mutation: Add a random reachable node.
-- Returns true only if the tree actually changed (AllocNode can silently
-- no-op when node.path / GetEffectiveAllocationPath is nil).
function optimizer.mutateAdd(spec, pinnedNodes)
	local reachable = optimizer.getReachableNodes(spec)
	if #reachable == 0 then return false end
	local node = reachable[m_random(#reachable)]
	if spec.allocNodes[node.id] then return false end
	spec:AllocNode(node)
	return spec.allocNodes[node.id] ~= nil
end

-- Mutation: Remove a random leaf node.
-- Returns true only if the tree actually changed.
function optimizer.mutateRemove(spec, pinnedNodes)
	local leaves = optimizer.getLeafNodes(spec, pinnedNodes)
	if #leaves == 0 then return false end
	local node = leaves[m_random(#leaves)]
	spec:DeallocNode(node)
	return spec.allocNodes[node.id] == nil
end

-- Mutation: Swap — remove a leaf, then add a reachable node.
-- On partial failure (remove succeeded, add found nothing) the spec is
-- restored, so callers never see a mutated tree reported as "no mutation".
function optimizer.mutateSwap(spec, pinnedNodes)
	local prev = optimizer.snapshotAlloc(spec)
	if not optimizer.mutateRemove(spec, pinnedNodes) then
		return false
	end
	if not optimizer.mutateAdd(spec, pinnedNodes) then
		optimizer.restoreAlloc(spec, prev)
		return false
	end
	return true
end

-- Apply a random mutation based on weights.
-- (Design's fourth operator, Path Shift, is intentionally dropped for v1:
-- it needs a real re-route algorithm; as a Swap alias it only wasted 10%
-- of iterations. Stretch goal at the end of this plan.)
function optimizer.mutate(spec, pinnedNodes)
	local roll = m_random(100)
	if roll <= 40 then
		return optimizer.mutateAdd(spec, pinnedNodes)
	elseif roll <= 70 then
		return optimizer.mutateRemove(spec, pinnedNodes)
	else
		return optimizer.mutateSwap(spec, pinnedNodes)
	end
end
```

(If snapshots change shape in Task 9, `mutateSwap`'s `prev` usage follows automatically — snapshot/restore stay symmetric.)

**Step 2: Commit** `git commit -am "fix(optimizer): restore spec on failed swap, detect no-op adds, drop duplicated path-shift operator"`

### Task 7: Pins and budget semantics

**Objective:** (a) `runSA` never allocated pinned nodes (only the coroutine did) — pinned notables were merely protected from removal, silently absent from results. (b) Pinned-but-unreachable was silently ignored (design: user must know). (c) Budget counted ascendancy and free-allocate nodes, unlike the game's `CountAllocNodes`.

**Files:**
- Modify: `src/Modules/TreeOptimizer.lua` — `ensurePinnedAllocated` (~303-313), `countUsedPoints` (~166-175), `initSAState`

**Step 1: `ensurePinnedAllocated` reports skipped pins** and is called from BOTH drivers via `initSAState`:

```lua
-- Ensure all pinned nodes are allocated (and paths to them).
-- Returns array of pinned node ids that could NOT be allocated (unreachable).
function optimizer.ensurePinnedAllocated(spec, pinnedNodes)
	spec:BuildAllDependsAndPaths()
	local skipped = { }
	for id in pairs(pinnedNodes) do
		local node = spec.nodes[id]
		if not node or not node.path then
			t_insert(skipped, id)
		elseif not node.alloc then
			spec:AllocNode(node)
			if not node.alloc then
				t_insert(skipped, id)
			end
		end
	end
	return skipped
end
```

In `initSAState`, after `state.spec = build.spec` and BEFORE the calculator is grabbed (pinning changes the baseline!):

```lua
	state.skippedPins = optimizer.ensurePinnedAllocated(state.spec, state.pinned)
```

Add `skippedPins = state.skippedPins` to `saResult`. Remove the standalone `ensurePinnedAllocated` call from the old coroutine body (gone with the Task-4 rewrite — verify `grep -c ensurePinnedAllocated src/Modules/TreeOptimizer.lua` == 2: definition + initSAState).

**Step 2: Budget via the game's own accounting** (DRY — `PassiveSpec.lua:1063` `CountAllocNodes()` already excludes ClassStart/AscendClassStart/ascendancy/free nodes and returns `used` as first value):

```lua
-- Count points used per the game's own accounting (excludes ascendancy,
-- free-allocate and start nodes, matching PassiveSpec:CountAllocNodes).
local function countUsedPoints(spec)
	return spec:CountAllocNodes()
end
```

**Step 3: Commit** `git commit -am "fix(optimizer): allocate pins in all SA paths, surface unreachable pins, count budget via CountAllocNodes"`

### Task 8: Convergence (early stop, reheat cap) + tuning knobs + result breakdown

**Objective:** The reheat branch reset `stagnantCount = 0` at exactly `maxStagnant`, so the 2,000-iteration early stop could never fire — every run burned 10,000 full calcs (~2-8 min). Task 4 already removed the reset and gated reheats by `maxReheats`; this task adds the missing verification + exposes the constants as `params` overrides (already wired through `opt()` in `initSAState`) and surfaces the offence/defence breakdown.

**Files:**
- Modify: `src/Modules/TreeOptimizer.lua` (verify only, from Task 4), `src/Classes/OptimizerPanel.lua` (progress/done label)

**Step 1: Verify convergence logic** in `saStep`: `stagnantCount` resets ONLY on new best; reheat fires at `>= maxStagnant` up to `maxReheats` times WITHOUT resetting the counter; `"earlystop"` returns at `>= earlyStopStagnant`. Trace by hand: from last improvement, iteration `+500` reheats (reheats=1), `+1000` reheat 2, `+1500` reheat 3, `+2000` earlystop. ✔

**Step 2: Show the breakdown in the Done label** (in `ResumeOptimizer`'s dead-coroutine branch, Task 10 rewrites the whole function — if working strictly in order, apply the label change there instead):

```lua
		self.controls.progressLabel.label = s_format(
			"Done! Best score: %.2f (offence x%.2f, defence x%.2f, %d iters, %d evals)",
			val.bestScore, val.bestOffence or 0, val.bestDefence or 0, val.iterations, val.evalCount or 0)
```

**Step 3: Commit** `git commit -am "fix(optimizer): reachable early stop, capped reheats, tunable SA params, offence/defence breakdown"`

---

## Phase C — Tree state and panel behavior

### Task 9: Snapshot/restore through the PassiveSpec API (keep mastery + undo)

**Objective:** `restoreAlloc` wrote `node.alloc`/`allocNodes` directly, bypassing `allocMode`, multiple-choice de-dup, and mastery bookkeeping — restored trees could hold two mutually exclusive multiple-choice options and lose mastery selections (deallocated nodes come back unselected; `DeallocSingleNode` clears mastery state around `src/Classes/PassiveSpec.lua:1055`). Also the design's undo integration was never wired.

**Files:**
- Modify: `src/Modules/TreeOptimizer.lua:85-111` (snapshot/restore)
- Reference: `src/Classes/PassiveSpec.lua` — READ FIRST: `AllocNode` (~988-1032), `DeallocNode`/`DeallocSingleNode` (~1042-1061), `AddUndoState`, and exactly where mastery selections live (audit: cleared near 1055-1058) and its field name (expect `node.masterySelections`; ADAPT the code below to the real field/shape).

**Step 1: Rich snapshot** — change the representation from a plain id-set to:

```lua
-- Snapshot current allocation (node ids + per-node state that must survive
-- restore: allocMode for weapon-set nodes, mastery selections).
function optimizer.snapshotAlloc(spec)
	local snapshot = { nodes = { }, allocMode = { }, mastery = { } }
	for id, node in pairs(spec.allocNodes) do
		snapshot.nodes[id] = true
		snapshot.allocMode[id] = node.allocMode
		if node.masterySelections then
			-- shallow-copy the selection table keyed by effect id
			local sel = { }
			for k, v in pairs(node.masterySelections) do sel[k] = v end
			snapshot.mastery[id] = sel
		end
	end
	return snapshot
end
```

(If mastery selections live on `spec.masterySelections[nodeId]` instead of the node, mirror that: snapshot keyed the same way.)

**Step 2: API-based restore** — deallocate everything through `DeallocNode`, re-add through `AllocNode` in ascending `pathDist` (a fully-allocated snapshot contains its own path nodes, so shallow-first guarantees each node's path is already allocated when reached):

```lua
-- Restore allocation through the PassiveSpec API (keeps allocMode,
-- multiple-choice invariants, mastery bookkeeping consistent).
function optimizer.restoreAlloc(spec, snapshot)
	local targetIds = snapshot.nodes or snapshot   -- tolerate legacy plain-set
	-- 1. deallocate everything currently allocated
	local toClear = { }
	for id in pairs(spec.allocNodes) do
		t_insert(toClear, id)
	end
	for _, id in ipairs(toClear) do
		local node = spec.nodes[id]
		if node then
			spec:DeallocNode(node)
		end
	end
	-- 2. re-allocate the target set, shallow nodes first so paths exist
	local ids = { }
	for id in pairs(targetIds) do
		t_insert(ids, id)
	end
	table.sort(ids, function(a, b)
		local na, nb = spec.nodes[a], spec.nodes[b]
		return (na and na.pathDist or 0) < (nb and nb.pathDist or 0)
	end)
	for _, id in ipairs(ids) do
		local node = spec.nodes[id]
		if node and not node.alloc then
			spec:AllocNode(node)
		end
	end
	-- 3. restore per-node state that AllocNode does not carry
	if snapshot.allocMode then
		for id, mode in pairs(snapshot.allocMode) do
			local node = spec.nodes[id]
			if node then node.allocMode = mode end
		end
	end
	if snapshot.mastery then
		for id, sel in pairs(snapshot.mastery) do
			local node = spec.nodes[id]
			if node then node.masterySelections = sel end
		end
	end
	spec:BuildAllDependsAndPaths()
end
```

If `AllocNode` takes extra args for weapon-set nodes (`allocMode`), check its signature and pass them; verify multiple-choice nodes don't need special re-add handling (the invariant assert at `PassiveSpec.lua:1016-1031` will fire during smoke testing if you got it wrong — that's your test).

**Step 3: Update every consumer of the old plain-set shape.** Tests do `result.bestAlloc[pinnedId] == true` → must become `result.bestAlloc.nodes[pinnedId] == true` (do in Task 11; list the sites with `grep -rn "bestAlloc\[" spec/`). Panel code only passes snapshots around opaquely — no change needed there.

**Step 4: Undo integration.** In `OptimizerPanel:StartOptimizer` (before creating the coroutine) and in `ApplyBestTree` (before `restoreAlloc`), call:

```lua
	self.build.spec:AddUndoState()
```

(Verify method name via `grep -n "function PassiveSpecClass:AddUndoState" src/Classes/PassiveSpec.lua`.)

**Step 5: Commit** `git commit -am "fix(optimizer): restore via PassiveSpec API preserving mastery/allocMode; register undo states"`

### Task 10: Panel behavior — error restore, unpin buttons, pin warnings, optimizer handle

**Objective:** (a) The coroutine-error path left a half-mutated tree. (b) No way to remove a pin except clicking the tree in Pin Mode. (c) Unreachable/skipped pins were silent. (d) Wire `GetOptimizer()` and undo.

**Files:**
- Modify: `src/Classes/OptimizerPanel.lua` — `StartOptimizer`, `ResumeOptimizer`, `PinNode`/`UnpinNode`, `Draw` (drop manual pin text, use buttons)

**Step 1: Replace `StartOptimizer`:**

```lua
function OptimizerPanelClass:StartOptimizer()
	if self.running then return end
	local opt = self:GetOptimizer()
	if not opt then
		self.controls.progressLabel.label = "Optimizer module not loaded"
		return
	end
	self.build.spec:AddUndoState()
	self.originalAlloc = opt.snapshotAlloc(self.build.spec)
	self.bestResult = nil
	self.running = true
	self.progressPct = 0
	self.controls.progressLabel.label = "Starting..."
	self.optimizerCoroutine = opt.createOptimizerCoroutine(self.build, {
		alpha = self.alpha,
		maxIterations = 10000,
		pointBudget = self.pointBudget,
		pinnedNodes = self.pinnedNodes,
		customWeights = nil,
	})
end
```

**Step 2: Restore the tree on the error path** in `ResumeOptimizer`:

```lua
	local ok, val = coroutine.resume(self.optimizerCoroutine)
	if not ok then
		self.running = false
		self.optimizerCoroutine = nil
		if self.originalAlloc then
			self:GetOptimizer().restoreAlloc(self.build.spec, self.originalAlloc)
			self.build.buildFlag = true
		end
		self.controls.progressLabel.label = "Error: " .. tostring(val) .. " (tree restored)"
		return
	end
```

And add the skipped-pins warning to the completion label (after the Done label from Task 8):

```lua
		if val.skippedPins and #val.skippedPins > 0 then
			self.controls.progressLabel.label = self.controls.progressLabel.label
				.. s_format("  [!%d pin(s) unreachable]", #val.skippedPins)
		end
```

**Step 3: Unpin buttons.** Replace the manual pin-text block in `Draw` (the `pinY = y + 78` loop) with real buttons refreshed whenever pins change:

```lua
function OptimizerPanelClass:RefreshPinButtons()
	for k in pairs(self.controls) do
		if k:find("^pinBtn") then
			self.controls[k] = nil
		end
	end
	for i, pin in ipairs(self.pinnedNodesList) do
		self.controls["pinBtn" .. pin.id] = new("ButtonControl"):ButtonControl(
			{ "TOPLEFT", self, "TOPLEFT" }, { 10 + (i - 1) * 150, 78, 140, 16 },
			"x " .. pin.name,
			function()
				self:UnpinNode(pin.id)
			end)
	end
end
```

Call `self:RefreshPinButtons()` at the end of `PinNode` and `UnpinNode`; delete the pin-text drawing loop from `Draw`.

**Step 4: Route `UpdateSearchResults` through `GetOptimizer()`** if not already done in Task 2.

**Step 5: Commit** `git commit -am "fix(optimizer): restore tree on error, unpin buttons, unreachable-pin warning, lazy optimizer handle"`

---

## Phase D — Tests and CI (never let this regress silently again)

Background (Task-11 forensics from the audit): the original plan's "run full test suite" step was NEVER executed — no `Run Tests` check run exists on any optimizer-era commit, and the integration asserts were tautologies (`bestScore` starts at 1.0 and only grows, so `bestScore >= baseScore` is always true).

### Task 11: De-vacuum the spec suite

**Objective:** Tests must fail loudly when scoring is broken, pins are ignored, or restore drops state.

**Files:**
- Modify: `spec/System/TestTreeOptimizer_spec.lua`

**Step 1: Update all snapshot-shape consumers** (`bestAlloc[x] == true` → `bestAlloc.nodes[x] == true`; same for any `originalAlloc` handling in tests).

**Step 2: Add these tests** (follow the file's existing busted style and `newBuild()` helper from `spec/System/HeadlessWrapper.lua`):

```lua
	it("scores candidates with an empty override diff (no double-count)", function()
		local build = newBuild()
		local seen = { }
		build.calcsTab.GetMiscCalculator = function()
			return function(override, useFullDPS)
				t_insert(seen, { override = override, useFullDPS = useFullDPS })
				return { CombinedDPS = 1000, LifeUnreserved = 3000 }
			end, { CombinedDPS = 1000, LifeUnreserved = 3000 }
		end
		local result = build.calcsTab.calcs.optimizer.runSA(build, {
			maxIterations = 30, pointBudget = 10, seed = 42,
		})
		assert.is_true(#seen > 0)
		for _, call in ipairs(seen) do
			assert.are.equal("table", type(call.override))
			assert.are.equal(0, #call.override)             -- must be an EMPTY diff...
			local k = next(call.override)
			assert.is_nil(k)                                -- ...keyed tables included
			assert.is_true(call.useFullDPS)
		end
	end)

	it("deterministic results with a fixed seed", function()
		local build = newBuild()
		local opt = build.calcsTab.calcs.optimizer
		local r1 = opt.runSA(build, { maxIterations = 50, pointBudget = 12, seed = 7 })
		local r2 = opt.runSA(build, { maxIterations = 50, pointBudget = 12, seed = 7 })
		assert.are.equal(r1.bestScore, r2.bestScore)
	end)

	it("allocates pinned nodes in the synchronous runSA path", function()
		local build = newBuild()
		local spec = build.spec
		local opt = build.calcsTab.calcs.optimizer
		-- pick a reachable Normal node near the start
		local pinnedId
		for id, node in pairs(spec.nodes) do
			if node.type == "Normal" and not node.alloc and node.pathDist == 1 then
				pinnedId = id
				break
			end
		end
		assert.is_not_nil(pinnedId)
		local result = opt.runSA(build, { maxIterations = 50, pointBudget = 15, pinnedNodes = { [pinnedId] = true }, seed = 11 })
		assert.is_true(result.bestAlloc.nodes[pinnedId])
	end)

	it("respects budget using game accounting (excludes free/ascendancy)", function()
		local build = newBuild()
		local opt = build.calcsTab.calcs.optimizer
		local result = opt.runSA(build, { maxIterations = 40, pointBudget = 8, seed = 5 })
		local restored = build.calcsTab.calcs.optimizer.snapshotAlloc(build.spec)
		-- bestAlloc is what's on the tree after runSA (it self-restores best)
		assert.is_true(result.iterations > 0)
		-- count game-accounted points on the live spec
		local used = build.spec:CountAllocNodes()
		assert.is_true(used <= 8)
	end)

	it("restoreAlloc round-trips through the PassiveSpec API", function()
		local build = newBuild()
		local spec = build.spec
		local opt = build.calcsTab.calcs.optimizer
		spec:AllocNode(spec.nodes[reachableFirst(spec)])   -- see existing helpers
		local snap = opt.snapshotAlloc(spec)
		local before = countAlloc(spec)
		opt.restoreAlloc(spec, snap)
		assert.are.equal(before, countAlloc(spec))
		-- every restored node must be reachable (paths intact)
		for id in pairs(snap.nodes) do
			assert.is_true(spec.allocNodes[id] ~= nil)
		end
	end)
```

(`reachableFirst`/`countAlloc` are small local helpers you write at the top of the file — 2 lines each, using `spec.allocNodes`.)

**Step 3: Fix the two pre-existing tautologies:**
- The "improves DPS" test: with `seed` fixed AND a seeded build whose seed tree allocates a couple of damage nodes, assert the real calc output actually moved: re-run `calcFunc({}, true)` after `runSA` and compare against a pre-run capture — `assert.is_true(newDPS >= baseDPS)` where both come from the same code path (never from `result.bestScore`).
- The pinned integration test now works deterministically thanks to Task 7 + seeds.

**Step 4: Commit** `git commit -am "test(optimizer): meaningful assertions — override diff, determinism, pin allocation, budget, restore round-trip"`

### Task 12: UI smoke spec (the layer no test ever touched)

**Objective:** Tasks 8/9's original three crash layers (new() guard, calcsTab ordering, nil self.build) all shipped green because zero tests construct TreeTab/OptimizerPanel. One spec catches the whole class of regressions.

**Files:**
- Create: `spec/System/TestOptimizerUI_spec.lua`

```lua
-- Smoke tests for the optimizer UI layer. These construct the real TreeTab
-- + OptimizerPanel via newBuild(); the original three startup crashes
-- (legacy new() ctor args, calcsTab-before-init ordering, nil self.build)
-- all surface here.
local newBuild = ...   -- copy the require/helper used by TestTreeOptimizer_spec.lua

describe("Optimizer UI", function()
	lazy_setup(function() ... end)   -- match TestTreeOptimizer_spec.lua's setup exactly

	it("TreeTab constructs with the optimizer controls", function()
		local build = newBuild()
		assert.is_not_nil(build.treeTab)
		assert.is_not_nil(build.treeTab.controls.optimizerPanel)
		assert.is_not_nil(build.treeTab.controls.optimizerToggle)
		assert.is_false(build.treeTab.controls.optimizerPanel.shown)
	end)

	it("panel pins and unpins through its own API", function()
		local build = newBuild()
		local panel = build.treeTab.controls.optimizerPanel
		local spec = build.spec
		local id, name
		for nid, node in pairs(spec.nodes) do
			if node.type == "Normal" then id, name = nid, node.dn break end
		end
		panel:PinNode(id, name, "Normal")
		assert.is_true(panel.pinnedNodes[id])
		assert.are.equal(1, #panel.pinnedNodesList)
		assert.is_not_nil(panel.controls["pinBtn" .. id])
		panel:UnpinNode(id)
		assert.is_nil(panel.pinnedNodes[id])
		assert.is_nil(panel.controls["pinBtn" .. id])
	end)

	it("HandleNodeClick toggles pin mode", function()
		local build = newBuild()
		local panel = build.treeTab.controls.optimizerPanel
		local node
		for _, n in pairs(build.spec.nodes) do
			if n.type == "Normal" then node = n break end
		end
		panel.pinMode = false
		assert.is_false(panel:HandleNodeClick(node))
		panel.pinMode = true
		assert.is_true(panel:HandleNodeClick(node))
		assert.is_true(panel.pinnedNodes[node.id])
		assert.is_true(panel:HandleNodeClick(node))    -- unpin
		assert.is_nil(panel.pinnedNodes[node.id])
	end)
end)
```

Match the actual require/setup boilerplate of the existing optimizer spec file — the ellipses above are placeholders ONLY for those two lines; everything else is final.

**Commit** `git commit -am "test(optimizer): UI smoke spec for TreeTab/panel construction and pin flow"`

### Task 13: CI green (the step that was skipped last time)

**Objective:** `Run Tests` + `Build Windows` + `Build macOS` green on the final commit. Locally there is no lua/busted — CI is the only runner; do not claim tests pass without a green run ID.

**Step 1:** `git push origin auto-optimizer-rebase:feature/auto-optimizer --force-with-lease`

**Step 2: Trigger the test workflow on this branch.** The `Run Tests` workflow only triggers on dev/PR. Two options, in order of preference:
1. If it supports manual runs: `gh workflow run "Run Tests" --repo p11primera/PathOfBuilding-PoE2 --ref feature/auto-optimizer` (find the exact name via `gh workflow list --repo p11primera/PathOfBuilding-PoE2`).
2. Otherwise add `workflow_dispatch:` and `feature/auto-optimizer` under branches to its triggers (mirror what was done for `build-macos.yml`), commit `ci: allow optimizer branch to run test workflow`, push.

**Step 3: Watch every run — ALWAYS with `--repo` (404 pitfall):**

```bash
RID=$(gh api "repos/p11primera/PathOfBuilding-PoE2/actions/runs?per_page=10" --jq '.workflow_runs[] | select(.head_sha | startswith("<SHA>")) | select(.name=="Run Tests") | .id' | head -1)
gh run watch $RID --repo p11primera/PathOfBuilding-PoE2 --exit-status --interval 30
```

**Step 4: On failure**, read the failing step log (`gh run view --repo p11primera/PathOfBuilding-PoE2 $RID --log-failed`), fix, push, re-watch. Repeat until all three workflows report success. **Do not summarize completion without the three green run IDs.**

---

## Acceptance Criteria (all must be verified, not assumed)

1. Opening any build (and any CompareEntry) no longer throws — proven by Task 12 spec passing in CI.
2. `runSA` with pinned nodes: pinned ids present in `bestAlloc.nodes` with a fixed seed (CI test).
3. Candidate scoring uses empty-override, `useFullDPS = true` (CI test intercepts calcFunc calls).
4. Budget respected under `CountAllocNodes` semantics on a tree containing ascendancy nodes (CI test; extend the budget test to allocate an ascendancy node first if the fixture allows).
5. Converged run returns in well under `maxIterations` — assert `result.iterations < 10000` on a plateau fixture, or verify via the Done label showing early exit.
6. Failed swap never leaves the spec mutated (add a unit test on `mutateSwap` with no reachable add: patch `getReachableNodes` to return `{ }` and assert spec unchanged after a false return).
7. After Stop / error / apply, `CountAllocNodes` and mastery selections match the pre-run snapshot (restore round-trip test).
8. Three green CI runs (Run Tests, Build Windows, Build macOS) on the final SHA, recorded with run IDs in the completion message.

## Stretch (only after all 13 tasks are green)

- Real Path-Shift operator: pick a random allocated notable with exclusive dependent leaves; deallocate the chain through the API; re-`AllocNode` the notable so `GetEffectiveAllocationPath` re-routes against the shrunken tree; restore snapshot on failure. Wire back into `mutate` at 10% (weights 36/27/27/10).
- Advanced per-stat defence weight editor (design doc §Advanced mode).
- Temperature schedule autotune: set `T0` from measured score-delta magnitudes during the first 50 evals.

## Known risks

- `restoreAlloc` via AllocNode may fight weapon-set `allocMode` nodes or multiple-choice asserts (PassiveSpec.lua:1016-1031 has hard asserts for exactly this) — the UI smoke + restore round-trip tests are the safety net; if asserts fire, check how PassiveTreeView drives alloc/dealloc on the weaponSet2 tab before inventing custom handling.
- `m_randomseed` determinism in the spec env assumes LuaJIT's default RNG (no explicit seeding elsewhere) — if two seeded runs still diverge, something else consumes randomness; check `GetTime` stub and `pairs`-order-dependent tie-breaks before blaming the seed.
- Headless `GetTime()` returns constant 0 (HeadlessWrapper.lua:103), so coroutine yield cadence is untestable in CI — the coroutine driver is covered structurally (same saStep as runSA, which IS tested).
