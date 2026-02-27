# Passive Tree Auto-Optimizer Design

**Goal:** Automatically allocate passive skill tree nodes to maximize a weighted combination of offence (DPS) and defence, using Simulated Annealing with the existing calc engine.

**Date:** 2026-02-27

---

## Architecture

The optimizer is a Lua module (`TreeOptimizer.lua`) that runs Simulated Annealing over passive tree allocations. It evaluates each candidate tree with the real calc engine via `getMiscCalculator`, so every score reflects actual DPS and defence — no approximations.

**Data flow:**
1. User sets pinned nodes, point budget, and offence/defence priority slider.
2. Optimizer snapshots build state (items, skills, config).
3. SA generates candidate trees by mutating allocations (add/remove/swap nodes).
4. Each candidate is scored via `getMiscCalculator` → full calc pipeline.
5. SA accepts or rejects based on score delta + temperature.
6. Best tree found is applied to PassiveSpec.
7. Runs as a background coroutine, yielding every ~100ms for UI responsiveness.

---

## Solution Representation

A solution is a **set of allocated node IDs** forming a connected tree from the class start node. Pinned nodes are always included and never removed.

### Mutation Operators

| Mutation | Weight | Description |
|----------|--------|-------------|
| Add | 40% | Allocate a random reachable node (1-hop from current tree) |
| Remove | 30% | Deallocate a random leaf node (no dependents) |
| Swap | 20% | Remove a leaf, add a reachable node |
| Path Shift | 10% | Find an alternate path to a notable/keystone |

**Invariants maintained after every mutation:**
- Tree remains connected from class start
- Pinned nodes remain allocated
- Used points ≤ budget (excess trimmed by removing random leaves)

---

## Scoring Function

```
score = α × (CombinedDPS / baseDPS) + (1 - α) × (defenceMetric / baseDefence)
```

- `α` = user slider (0.0 = pure defence, 1.0 = pure offence, default 0.5)
- `CombinedDPS` from `output.CombinedDPS` (or `FullDPS` when available)
- `defenceMetric` = weighted sum of normalized defensive stats:
  - `LifeUnreserved / 3000`
  - `EnergyShield / 3000`
  - `Armour / 10000`
  - `Evasion / 10000`
  - `LifeRegenRecovery / 500`
  - `EnergyShieldRegenRecovery / 1000`

Both terms are normalized against the starting tree's values, so they operate on the same scale (proportional improvement).

**Advanced mode:** Users can override individual defence weights.

---

## SA Parameters

| Parameter | Value |
|-----------|-------|
| Initial temperature | 1.0 |
| Cooling rate | 0.9997 per iteration (geometric) |
| Default iterations | 10,000 |
| Acceptance | `exp(-Δscore / T)` for worse moves; always accept improvements |
| Reheat | After 500 iterations without improvement, reheat to `T₀ × 0.5` |
| Early stop | After 2,000 iterations without improvement |
| Seed | User's current tree allocation |
| Eval time | ~10–50ms per iteration (full calc engine) |
| Total time | ~2–8 minutes for 10K iterations |

---

## UI Design

### Tree Tab Controls (bottom bar)

- **"Optimize Tree" button** — opens the optimizer panel
- **Offence/Defence slider** — SliderControl (0–1)
- **Point budget** — EditControl (numeric, defaults to available points)
- **"Pin Mode" toggle** — enables click-to-pin on tree
- **"Start" / "Stop" button** — begins or cancels optimization
- **Progress label** — "Optimizing... 42% (best: +35% DPS, +12% Life)"

### Optimizer Panel (collapsible drawer below tree)

- Best score display (offence/defence breakdown)
- Pinned nodes list with remove buttons
- Node search bar (pin by name)
- Advanced weights (collapsible sub-panel)
- "Apply Best Tree" / "Reset" buttons
- Iteration count and temperature display

---

## Files Affected

| Action | File |
|--------|------|
| Create | `src/Modules/TreeOptimizer.lua` — SA engine, mutations, scoring |
| Create | `src/Classes/OptimizerPanel.lua` — UI panel control |
| Modify | `src/Classes/TreeTab.lua` — add optimizer button and panel |
| Modify | `src/Classes/PassiveTreeView.lua` — pin-mode click handling |
| Modify | `src/Classes/CalcsTab.lua` — expose `GetMiscCalculator` for optimizer |
| Create | `spec/System/TestTreeOptimizer_spec.lua` — unit + integration tests |

---

## Testing Strategy

**Unit tests:**
- Each mutation produces a connected tree
- Scoring matches expected values for known inputs
- Pinned nodes survive all mutations
- Point budget never exceeded
- SA acceptance probability is correct

**Integration tests:**
- Load a build, run optimizer, verify DPS improves
- Undo/redo round-trips correctly
