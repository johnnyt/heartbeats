# Holding bay — slides to relocate

These slides were originally written for §2 (the Horde section) but compared
libring to Horde before libring had been introduced to the audience. They are
parked here until §4 (libring + consistent hashing) is ported into the deck.

**Intended placement:** at the end of §4, after libring has been explained,
as the moment where we finally pull both approaches up against each other.

**To reinstate:** paste these slides back into `slides.md` at the end of §4
(after the libring content, before the §5 section divider).

---

## Slide A — "The contrast" (Diagram 3, HordeVsRing component)

```markdown
---
clicks: 1
---

# The contrast

<HordeVsRing :clicks="$clicks" />

<!--
Click 0: both panels visible.<br>
LEFT: small nodes around a fuzzy gossip cloud; two yellow duplicate worker(sub-42) pids floating inside, pulsing.<br>
RIGHT: three big nodes, each containing its own mini-ring; each shows the same answer "→ b@".<br>
<br>
Click 1: LEFT — cloud thickens, one duplicate gets a red strike and dims; amber caption "convergence window = duplicate work" lands.<br>
RIGHT — emerald caption "same answer from each node — no gossip needed" lands.<br>
<br>
Narration as you click:<br>
"Both diagrams show the same setup: three nodes, one key (sub-42)."<br>
"On the left, Horde gossips a CRDT to converge on ownership. Until it does, both A and C believe they own sub-42 — two workers running."<br>
*click*<br>
"When the CRDT converges, one gets killed. That's the convergence window."<br>
"On the right, each node computes the answer locally from the ring. Same membership in, same answer out. No coordination on the hot path."
-->
```

---

## Slide B — "Different tradeoffs for different shapes of problem"

```markdown
---
layout: center
---

# Different tradeoffs for different shapes of problem

<div v-click class="mt-8 text-xl opacity-85 max-w-3xl mx-auto leading-relaxed">

Horde is the right answer when you need <strong>cluster-wide uniqueness guarantees</strong> and can tolerate the convergence window.

</div>

<div v-click class="mt-6 text-xl opacity-85 max-w-3xl mx-auto leading-relaxed">

libring is the right answer when you want <strong>deterministic placement</strong> and the workload tolerates a brief duplicate during a netsplit.

</div>

<div v-click class="mt-10 text-2xl text-amber-400 font-semibold">

Two primitives, composed. That's the talk.

</div>

<!--
This is the comparison payoff slide. Lands after libring has been introduced and the audience has seen the placement code.<br>
The first click validates Horde for its workloads.<br>
The second click validates libring for ours.<br>
Final click lands the thesis.
-->
```

---

## Notes for relocation

- The original closing line ("decomposing Horde into its two primitives") was
  pre-§4. After §4, the audience knows the two primitives, so it changes to
  "Two primitives, composed." Updated above.
- The `HordeVsRing.vue` component is in `components/` and remains imported
  automatically — no extra wiring needed when reinstating.
