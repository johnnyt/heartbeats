# TODO

Living state of in-flight work. Read this first when starting a fresh
session. Pair with `AGENTS.md` for repo conventions and the slides
authoring rules.

## Conference talk — slides

Source: `docs/talk-outline.md` (full outline, ~45 min).
Deck: `docs/slides/slides.md` (Slidev).
Components: `docs/slides/components/*.vue`.

### Done

- **§1 The Problem** — 6 slides + `PlacementQuestion` component (Diagram 1)
- **§2 How We'd Solve This in Elixir Today** — restructured as
  Horde-on-its-own-terms (does *not* compare to libring yet):
  - `:global` intro + drawbacks
  - `GlobalRegisterRace` component (Diagram 2 — register race, netsplit, murder)
  - Swarm one-slide aside
  - Horde mechanics (code, what it gives you)
  - "How does Horde know who owns what?" (CRDT explanation)
  - "What happens during convergence?" (the cost)
  - "Is the convergence window the right tradeoff?" (honest close)
- **§3 The Elixir Primitives** — 9 slides: cluster as queryable thing,
  `monitor_nodes`, libcluster, `:erpc` variants, live demo callout
  (uses `Placement.stats/0`), naïve placement breakdown, "deterministic +
  stable" requirements
- **`HordeVsRing` component (Diagram 3)** — built and working. *Slide that
  uses it is parked in the holding bay until §4 lands.*

### Pending — slides

| Section | Diagram(s) needed | Notes |
|---|---|---|
| Diagram 4 | `:erpc` in one frame | Placeholder in §3; simplest of the remaining diagrams |
| **§4 — Consistent Hashing & libring (7 min)** | Diagram 5 (Mod-N reshuffle), **Diagram 6 (the 6-frame ring storyboard)** | Diagram 6 is the talk's centerpiece — biggest visual lift remaining. Full storyboard already in `docs/talk-outline.md` §4b. |
| §5 — Placement (6 min) | Diagram 7 (`:nodedown` recovery) | Scale-up/down demo replaces the old "Inject Chaos" demo |
| §6 — Zero-Downtime Deploys (6 min) | Diagram 8 (rolling deploy timeline) | "The graph staying flat is the whole talk in one image" |
| §7 — Caveats (3 min) | Diagram 9 (optional, "When to use this") | When *not* to use this approach |
| §8 — Wrap (2 min) | Diagram 10 (closing image, callback to Diagram 1) | |

### Holding bay — reinstate at end of §4

`docs/slides/HOLDING-BAY.md` holds two slides that were originally in §2 but
were comparing libring to Horde before libring had been introduced. They are
intended to land at the **end of §4** (after libring is shown), as the moment
we finally pull both approaches up against each other.

- **Slide A**: "The contrast" (uses `HordeVsRing` component)
- **Slide B**: "Different tradeoffs for different shapes of problem"

To reinstate: paste both slides into `slides.md` at the end of §4 (after the
libring content, before the §5 section divider). The closing line of slide B
has already been updated for the post-§4 placement ("Two primitives,
composed" rather than the pre-§4 "decomposing Horde into its two primitives").

## App / dashboard

- **Scale demo affordance.** The §5 talk outline now says "stop node `d`" /
  "start node `d` back up" via raw `iex`. There is no dashboard button for
  this — only **Rolling Deploy** and **Clear all** remain after the chaos
  removal. Decide: add **Scale Down** / **Scale Up** buttons, or leave it
  as `iex`-driven for the demo? Either is defensible; raw `iex` arguably
  better reflects what a real ops scenario looks like.
- No other open work. Chaos removal verified: `mix test` → 62 tests, 0
  failures.

## Outline doc

`docs/talk-outline.md` reflects all current decisions:
- §2 restructured (no libring comparisons inside §2)
- §4d added (relocated Diagram 3 + comparison)
- §5 demo replaced (scale-up/down, not chaos)
- Hard-kill iex beat preserved in §6
- Timing summary updated
