# Spreading Long-Running Workloads Across an Elixir Cluster
*A story about consistent hashing, `:erpc`, and zero-downtime deploys*

**Total: ~45 min.** Audience: Elixir/BEAM folks, already bought in on the
runtime. We assume shared OTP intuition (processes, supervision, message
passing, `Node`/`:erpc`) and don't justify Elixir as a choice — the audience
already made it. The comparison points are *other Elixir patterns* for this
problem (`:global`, Horde, Swarm), not other ecosystems. The Heartbeats demo is
**woven through** sections 3–6, not held to the end.

---

## Section 1 — The Problem (5 min)

**Goal:** anchor the audience in a concrete workload before we look at solutions.

- Define the workload: **N long-running GenServers that each need a home** —
  Absinthe subscription heartbeats, Phoenix Channel sockets, per-tenant
  pollers, log tailers, "one worker per X" anything.
- Properties that make placement hard:
  - **Stateful** — round-robin at the LB doesn't help; the *process* is the
    state.
  - **Long-lived** — placement decisions stick for hours or days, not the
    milliseconds a task takes.
  - **Membership churn is the steady state, not an exception.** Nodes leave
    (deploys, autoscaling, crashes) and join (scale-up, restarts) constantly.
    Whatever places workers has to redistribute on every one of those events
    without dropping work.
- The two questions every BEAM-native solution must answer:
  1. **Which node runs the GenServer for key X?**
  2. **How does any other node send it a message?**
- Both questions reduce to one: ***placement.*** Once you can answer "who owns
  X," `:erpc` (or a `{name, node}` send) handles the rest — that's the next
  35 minutes.

> **Speaker notes:** Quick show of hands — "who's reached for Horde? For
> `:global`? For Swarm? For a homegrown registry on top of `:pg`?" Calibrates
> the room and seeds Section 2. Don't dwell — 90 seconds max on the survey.

📊 **Diagram 1 — "The placement question"**
- Static frame: row of 4 nodes (matches the live demo cluster size), scattered
  worker dots colored by tenant.
- Two large arrows from a "register" cloud and a "talk to me" cloud, both with
  question marks pointing at the cluster.
- *Animation:* the question marks pulse; on click, they're replaced by a single
  "?" centered over the cluster — emphasizes that both questions reduce to one:
  *placement.*

---

## Section 2 — How We'd Solve This in Elixir Today (6 min)

**Goal:** name the BEAM-native prior art so the libring solution feels earned,
not magical. The audience is bought in on Elixir — they're not wondering "why
not Kafka," they're wondering **"why not Horde?"** Answer that head-on.

### 2a. The naïve cluster registry: `:global` (and Swarm, briefly)

```elixir
:global.register_name({:worker, sub_id}, self())
:global.whereis_name({:worker, sub_id})
#=> #PID<12345.678.0> or :undefined
```

- Looks like the obvious answer: the runtime already tracks cluster membership,
  let it track names too.
- Where it falls down for *placement*:
  - **No placement policy.** Whichever node calls `register_name/2` first owns
    the name. Add a node and existing names don't redistribute — there *is* no
    "~1/N moves" property; there's no movement at all.
  - **Cluster-wide locking on register.** Every name registration is a full
    mesh round-trip. Fine at 10 names, painful at 10k.
  - **Netsplit conflict resolution kills processes by default.** When two
    partitions heal and both have registered the same name, `:global`'s
    default resolver exits one of them. Most teams meet this property in prod.
- **Swarm** (one-liner): tried to fix this with handoff + an internal hash ring.
  Largely unmaintained now — but worth naming so the room knows you know the
  history. The ring is the *idea* Swarm got right; we're going to build directly
  on it.

📊 **Diagram 2 — "`:global` register race"**
- Three nodes A/B/C, each holding a `register({:worker, 42}, …)` envelope.
- *Animation:* all three envelopes fly toward a shared "lock" in the center;
  one wins, the other two return as `{:error, :already_registered}`.
- *Second beat:* a lightning-bolt netsplit between A and {B,C}. Both sides
  re-register `{:worker, 42}` locally. Heal the split → one of the two PIDs
  flashes red and dies. Caption: ***"name uniqueness, by murder."***

### 2b. Horde — distributed registry + supervisor

```elixir
Horde.DynamicSupervisor.start_child(MySup, {Worker, sub})
Horde.Registry.lookup(MyRegistry, sub.id)
```

- Built explicitly for "distributed supervisor that rebalances on membership
  change." This is the mental model the audience is already running — don't
  dodge it.
- What Horde gives you:
  - Auto-rebalance on `:nodeup`/`:nodedown`.
  - Cluster-wide name registry with handoff.
  - Process state hand-off hooks on migration.

> **Speaker notes:** Establish that Horde is a real, well-built library
> doing real work. Don't compare to anything yet — describe it on its own
> terms. The audience will form opinions about its tradeoffs once we explain
> the mechanics.

### 2c. How does Horde know who owns what?

The audience knows Elixir but not necessarily CRDTs. One slide of mechanics
before we look at consequences:

- **Each node holds its own copy of the registry.** Local read, no
  round-trip.
- **Updates gossip between nodes via delta-CRDTs.** Powered by the
  `DeltaCrdt` library. Each node sends only what changed.
- **All copies converge — eventually.** Milliseconds in a healthy cluster;
  longer under load or partition.

> **Speaker notes:** Land "eventually is not zero" hard — that's the seed
> for the next slide. If anyone's never seen a CRDT, this level of detail is
> enough; they don't need the math.

### 2d. What happens during convergence?

This is the heavyweight slide of §2 — give it a beat.

- **Two nodes can disagree about ownership.** Before gossip lands, node A
  thinks it owns `sub-42`; node C also thinks it owns `sub-42`. Both start
  workers.
- **Two workers run for the same key** for the duration of the convergence
  window — often milliseconds, occasionally longer.
- **Horde resolves once gossip converges** — the CRDT picks a winner, the
  other worker gets terminated. The Horde README is explicit about this.
  Teams in production hit it.

📊 **Diagram 2c — "`:global` register race"** *(already in the deck; ends §2a)*
*The Horde-vs-libring side-by-side diagram now lives at the end of §4 —
the audience needs to see the ring before the comparison can land.*

### 2e. Is the convergence window the right tradeoff?

- For workloads that need **cluster-wide uniqueness guarantees** — clearly
  yes. Horde is the right tool.
- For workloads where a brief duplicate during a netsplit is *unacceptable* —
  we can ask the runtime for less, and do more locally.

> **Speaker notes:** This is the honest close to §2. We're not comparing to
> the alternative yet — that comes after §4, once the audience knows what
> the alternative *is*. "Ask the runtime for less, do more locally" is the
> thesis of §3–§6 in one phrase.

---

## Section 3 — The Elixir Primitives (8 min, *demo woven in*)

**Goal:** the two superpowers we'll compose. Most of the room knows OTP; we're
framing the *cluster* as a first-class concept.

### 3a. The cluster is a thing you can ask questions of

```elixir
Node.self()        #=> :"a@127.0.0.1"
Node.list()        #=> [:"b@127.0.0.1", :"c@127.0.0.1"]

:net_kernel.monitor_nodes(true)
# inbox now receives:
#   {:nodeup,   :"b@127.0.0.1"}
#   {:nodedown, :"b@127.0.0.1"}
```

- `libcluster` discovers peers — `LocalEpmd` for this demo,
  `Kubernetes`/`Gossip`/`DNSPoll` in prod. One config block, no code.
- `monitor_nodes/1` is the foundation for *automatic* rebalance later: any
  GenServer can subscribe and react.

> **Speaker notes:** For the BEAM-curious in the room: `Node.list()` is *not*
> a service-discovery API call. The runtime maintains the membership; you're
> reading a local data structure. This is the difference that makes everything
> else possible.

### 3b. `:erpc` — calling code on another node

Build it up progressively. Switch to terminal *here* and run each line live.

```elixir
# Synchronous — returns a value or raises
:erpc.call(:"b@127.0.0.1", Heartbeats.WorkerSupervisor, :start_worker, [sub])

# Fire-and-forget
:erpc.cast(node, Heartbeats.Placement, :rebalance_local, [])

# Parallel fan-out across the cluster, results keyed by node
:erpc.multicall([node() | Node.list()], Heartbeats.Placement, :stats, [])
```

🖥️ **Live demo (~90s)** — in the dashboard's iex session:
```elixir
:erpc.multicall([node() | Node.list()], Heartbeats.Placement, :stats, [])
#=> [{:ok, %{worker_count: 0, node: :"a@127.0.0.1"}},
#    {:ok, %{worker_count: 0, node: :"b@127.0.0.1"}},
#    {:ok, %{worker_count: 0, node: :"c@127.0.0.1"}}]
```
Then point at the **Nodes** card on the dashboard — note that this is *exactly*
what `ClusterLive` does on every tick. The dashboard isn't talking to a
service; it's calling a function on three BEAMs in parallel.

📊 **Diagram 4 — "`:erpc` in one frame"**
- Two BEAM lozenges side by side, labeled `a@` and `b@`.
- *Animation step 1:* arrow from `a@` to `b@` labeled
  `:erpc.call(b, Mod, :fun, [arg])`.
- *Step 2:* `b@` runs the function (small spinner inside `b@`).
- *Step 3:* return-value arrow back to `a@`.
- Caption morph: **"no service discovery / no auth handshake / no JSON / no
  HTTP — just call a function."**

### 3c. Naïve placement, and why it's not enough

```elixir
Enum.random([node() | Node.list()])
```

- Works… until a node leaves. The other nodes have no way to compute "what was
  on the dead one" without a registry — which means we just rebuilt the same
  coordination problem we were trying to avoid.
- We need a placement function that's **deterministic** (same key → same node)
  and **stable** (one membership change → small reassignment).

> **Speaker notes:** This is the pivot. We've earned the runtime mechanics; now
> we need a *policy* for placement. Cue the ring.

---

## Section 4 — Consistent Hashing & libring (7 min)

**Goal:** picture-first explanation of consistent hashing, then libring as the
four-line implementation.

### 4a. Naive hashing breaks under membership changes

```elixir
nodes = [node() | Node.list()]
Enum.at(nodes, :erlang.phash2(id, length(nodes)))
```

- Add a 4th node → ~75% of items move. Every membership change = mass
  migration.

📊 **Diagram 5 — "Mod-N reshuffle"**
- Top: 3 columns (nodes), 12 colored dots distributed.
- *Animation:* a 4th column slides in; nearly every dot jumps column. Counter
  in the corner ticks **"reassigned: 9 / 12"**. Counter flashes red.

### 4b. The ring

📊 **Diagram 6 — "The hash ring"** *(centerpiece — full storyboard below)*

This diagram does the heaviest lifting in the talk. Build it in **six discrete
frames**, each held long enough to narrate. Use a single canvas; transitions
between frames are animated, not slide-cuts.

**Visual conventions (consistent across all frames):**
- Ring drawn as a thick gray circle, ~60% of the slide height.
- Nodes are filled circles labeled `A`, `B`, `C` (and later `D`), each in a
  distinct hue (A=indigo, B=teal, C=amber, D=rose).
- Items are smaller dots, colorless until they "claim" an owner — then they
  inherit that owner's hue.
- An "ownership arc" is a translucent wedge of the owner's color, swept from
  the *previous* node clockwise to *that* node. This is the visual core of the
  diagram: an item's color is the color of the arc it sits in.

**Frame 1 — "Hash a key onto the ring."**
- Empty ring with one node `A` at the 12 o'clock position.
- A single item dot named `sub-42` flies in from off-canvas. A label appears:
  `hash("sub-42") = 0x8a91…`. The dot lands at its hashed position on the
  circumference (say 4 o'clock).
- Narration: *"Every key — subscription id, tenant id, whatever — hashes to a
  point on the ring."*

**Frame 2 — "Walk clockwise to find the owner."**
- A small arrow grows clockwise from `sub-42` along the ring until it hits
  `A`. `sub-42` adopts A's indigo color.
- Narration: *"Walk clockwise. First node you hit owns the key. With one node,
  trivially everyone goes to A."*

**Frame 3 — "Add nodes B, C, D; arcs appear."**
- `B`, `C`, `D` fade in at 3, 6, and 9 o'clock.
- Four translucent arcs sweep into existence, one per node, color-matched.
- 15 more item dots rain in (16 total), each landing at its hashed position
  and adopting the color of the arc it lands in. End state: ~4 items per node,
  evenly distributed.
- Counter widget appears in the corner: **"items: 16 · A:4 B:4 C:4 D:4"**.
- Narration: *"With four nodes, each owns the arc clockwise of its
  predecessor. Items inherit the arc's color."*

**Frame 4 — "Add a 5th node. Watch what moves."**
- `E` fades in at, say, 1:30 — between `A` and `B`.
- A new green arc sweeps in, **carved out of the existing indigo (A) arc**.
  Items that fall inside the new green arc cross-fade from indigo → green with
  a visible little jump-animation.
- The other three arcs (B's teal, C's amber, D's rose) **don't change at all**
  — visually call this out by *briefly desaturating them* during the
  transition, then restoring.
- Counter updates: **"reassigned: 1 / 16"**. Pin a callout next to it: ***"~1/N
  moves. Compare: mod-N moved ~12/16."***
- Narration: *"Adding E only steals from its clockwise neighbor's arc. Three
  of the four existing nodes don't notice anything changed."*

**Frame 5 — "Remove a node. Same property, in reverse."**
- `B` fades out (simulating `:nodedown`). B's teal arc dissolves; the items
  that were in it cross-fade to C's amber (their new clockwise neighbor).
- A, D, and E arcs are untouched.
- Counter: **"reassigned: 4 / 16"**.
- Narration: *"Same story on departure. Only the dead node's arc redistributes
  — to a single neighbor."*

**Frame 6 — "Zoom out: virtual nodes."**
- The camera zooms out and the four node markers each **explode into ~128
  small marks** scattered around the ring, color-coded to their owner.
- The arcs become *interleaved confetti* of all four colors instead of four
  big wedges.
- Show the new item-distribution counter: still ~3 per node, but visibly
  smoother under load.
- Narration: *"Real ring libraries don't place each node once — they place each
  node ~128 times around the ring as 'vnodes'. That's how the spread stays
  even when you have wildly different numbers of items."*

> **Speaker notes (important — bridges to the live demo):** The "only neighbors
> change" property is true for the *no-vnode* ring (Frames 1–5). With vnodes,
> every real node has segments scattered all around the ring, so when a node
> dies its load redistributes across **every** surviving node — but still only
> ~1/N of items move in total. In the live demo you'll see all three survivors
> pick up roughly equal slices of the dead node's work. That's vnodes earning
> their keep — even spread is the trade for "single-neighbor" locality.

**Animation polish notes for design:**
- Each frame transition should be **≤ 800ms**; the diagram should feel
  *deliberate*, not flashy. Easing: `cubic-bezier(0.4, 0, 0.2, 1)`.
- Item dots should have a tiny "settle" wiggle when they land on the ring —
  enough to feel physical, not so much it's noisy.
- The counter widget is the *secret weapon* — it converts the visual story into
  a number the audience can quote later. Always show it; always update it
  during a transition, not after.
- Consider holding Frame 4 on screen while the speaker explicitly contrasts it
  with the mod-N diagram (Diagram 5). A two-up "before/after" composite is a
  nice optional 7th frame.
- All color choices should pass WCAG AA against the slide background.

### 4c. libring in 4 lines

```elixir
# config/config.exs
config :libring,
  rings: [heartbeats: [monitor_nodes: true, node_type: :visible]]
```

```elixir
HashRing.Managed.key_to_node(:heartbeats, subscription_id)
#=> :"b@127.0.0.1"
```

- `monitor_nodes: true` is the magic word. libring hooks
  `:net_kernel.monitor_nodes/1` and updates the ring on `:nodeup`/`:nodedown`.
  **You never write membership-tracking code.**
- Show `Heartbeats.Ring` (`lib/heartbeats/ring.ex`) — it's a thin wrapper:
  `owner/1`, `members/0`, `cordon/1`, `uncordon/1`. ~30 lines.

> **Speaker notes:** Land the `monitor_nodes: true` line hard — this is where
> two primitives compose. libring leans on the runtime's `monitor_nodes`, so by
> the time *your* code asks "who owns key X?", the ring is already correct for
> current membership. There's no callback for *you* to wire.

### 4d. Now — Horde vs. the ring

Now that the audience has seen the ring, the comparison can land.

📊 **Diagram 3 — "Horde vs. ring, side by side"** *(relocated from §2)*
- Two-up layout. Left: Horde. Right: libring + `:erpc`.
- **Left frame:**
  - Box labeled `Horde.Registry` with a dashed CRDT-gossip cloud connecting
    A↔B↔C.
  - Two pulsing pids labeled `worker(sub-42)` — one on A, one on C —
    rendered in yellow during the "convergence window."
  - After a beat, the cloud thickens, one pid fades out. Caption:
    ***"eventually consistent · convergence window = duplicate work."***
- **Right frame:**
  - Three nodes A/B/C with an identical ring drawn inside *each* node.
  - `sub-42` hashes → arrow points to `B` from all three nodes simultaneously.
  - Caption: ***"same membership in → same answer out. No gossip on the hot
    path."***
- The visual contrast — fuzzy cloud vs. three matching rings — does most of
  the work.

**The tradeoff statement, plainly:**
- Horde is the right answer when you need **cluster-wide uniqueness
  guarantees** and can tolerate the convergence window.
- libring is the right answer when you want **deterministic placement** and
  the workload tolerates a brief duplicate during a netsplit.
- Two primitives, composed. That's the talk.

> **Speaker notes:** Be respectful — Horde's maintainers are in this community,
> and Horde is the right answer for its workloads. The point isn't "Horde is
> wrong" — it's that decomposing the problem gives you something simpler for
> the *placement* shape of it.

> **Audience-bridge line:** "If you've reached for Horde and it worked — keep
> using it. If the convergence window bit you, or you wanted to *see* the
> placement decision in your code, the next 15 minutes are for you."

---

## Section 5 — Putting It Together: Placement (6 min, *demo woven in*)

**Goal:** show that the entire scheduler is three lines because the runtime did
the rest.

```elixir
def place(%Subscription{id: id} = sub) do
  owner = Ring.owner(id)
  :erpc.call(owner, WorkerSupervisor, :start_worker, [sub])
end
```

- **That's the scheduler.** No queue, no dispatcher, no coordinator.
- Walk through `Heartbeats.Placement` (`lib/heartbeats/placement.ex`):
  - One GenServer per node, locally named.
  - `init/1` calls `:net_kernel.monitor_nodes(true)`.
  - On `:nodeup`/`:nodedown` → `rebalance_local/0`.
  - `rebalance_local/0`: for each local worker, re-ask the ring; if the owner
    changed, `:erpc.cast` the new owner and stop the local copy.

```elixir
def handle_info({nodeevt, _node}, state) when nodeevt in [:nodeup, :nodedown] do
  rebalance_local()
  {:noreply, state}
end
```

- The **Worker** opts into its own migration on `:rebalance`. Highlight this
  as the BEAM-native pattern: each process is responsible for itself; no
  central mover yanks workers around.

🖥️ **Live demo (~2 min) — scale down, then back up** *(start at 4 nodes: a, b, c, d)*
1. In the dashboard, click **Spawn** with 50 subscriptions @ 5s.
2. Watch the **Subscriptions by node** cards even out (~12-13 per node).
3. Stop node `d` (e.g., kill the running `iex` for `d@…`).
   - `:nodedown` propagates; the ring redraws on every survivor.
   - Each survivor's count rebounds from ~12 → ~16 — *only ~1/4 of workers
     actually moved.* That's the ring's stability property in action.
4. Start node `d` back up (`iex --name d@... -S mix`).
   - `:nodeup` propagates; the ring redraws on every node.
   - Workers redistribute back toward ~12-13 each.
5. Note the **callbacks received** counter never stops climbing.

📊 **Diagram 7 — "`:nodedown` recovery"** — three frames, animated as a sequence
- *Frame 1:* 4 nodes A/B/C/D, workers as dots colored by ring zone.
- *Frame 2:* node B vanishes (poof animation). Surviving nodes display a
  pulsing `:nodedown` envelope flying in. Ring redraws: B's vnodes dissolve,
  A/C/D each absorb a slice.
- *Frame 3:* dotted arrows show orphaned workers being adopted on A, C, and D
  (roughly evenly — vnodes again). Counter shows **total worker count:
  unchanged · moved: ~1/4**.
- *Animation note:* end on a slow cross-fade back to frame 1's color scheme but
  on 3 nodes — emphasizes that the cluster is now in a new healthy state, not
  a degraded one.

> **Speaker notes:** If the scale-down feels too fast in the room, run it
> twice. The "boring" recovery *is* the punch line — there's no banner, no
> incident, no on-call. The hard-kill in the deploy section (§6) shows the
> same property under more violent conditions; this section shows it under
> the everyday autoscaling case.

---

## Section 6 — Zero-Downtime Deploys (6 min, *demo woven in*)

**Goal:** the payoff. Cordon/drain/uncordon falls out of the same primitives.

```elixir
def rolling_deploy(nodes) do
  for node <- nodes do
    Ring.cordon(node)              # remove from ring on every node (:erpc fan-out)
    wait_until_drained(node)       # workers self-migrate; we just watch
    Ring.uncordon(node)            # re-add; trigger rebalance_local on every node
    Process.sleep(@settle_ms)
  end
end
```

- **Cordon** = remove from the ring everywhere. Workers on the cordoned node
  see "I'm not the owner anymore" on their next `:rebalance` tick and `:erpc`
  themselves to the new owner.
- **Drain** = wait for the local worker count on that node to hit zero. *No*
  central tracking; we're just polling `WorkerSupervisor`.
- **Uncordon** = put it back. New work re-spreads naturally.
- Show `Heartbeats.GracefulShutdown` — last child in the supervision tree, runs
  cordon + drain in `terminate/2`. A `kubectl rollout restart` looks identical
  to clicking the button.

🖥️ **Live demo (~2 min) — rolling deploy + hard kill** *(4-node cluster)*
1. Click **Rolling Deploy**. Talk over the ~20s rotation:
   - "Watch B's worker count hit zero — that's the drain."
   - "Watch A, C, and D absorb evenly — that's the ring."
   - "Watch the callbacks counter — that's the SLO."
2. In one iex: `Ctrl-C, a` to hard-kill node D.
3. `:nodedown` recovery in ~5s. Survivors pick up D's work.
4. Restart D with `iex --name d@... -S mix` → `:nodeup` → workers redistribute.

📊 **Diagram 8 — "Rolling deploy timeline"**
- Gantt-style: 4 horizontal lanes (nodes A, B, C, D) over a ~20s timeline.
- Each lane has colored bands: **active (green) / cordoned (yellow) / draining
  (orange) / restarting (gray) / active (green)**.
- A worker-count line graph runs underneath, summed across all live nodes.
- *Animation:* the timeline plays from left to right. The summed worker-count
  line is **flat the entire time** — that's the SLO promise. Highlight it on
  each pass.

> **Speaker notes:** The graph staying flat is the whole talk in one image. If
> you only get one slide right, this is it.

---

## Section 7 — Caveats & When *Not* to Use This (3 min)

Earn trust by being honest about boundaries.

- **Workers must be placeable anywhere.** Anything pinned to a node (local
  file, GPU, attached disk) breaks the model.
- **Migration cost.** Workers in this demo are stateless between heartbeats;
  if yours have warm state, you need to checkpoint or accept a re-warm on
  migration.
- **Flap windows.** If a node bounces (`:nodedown` → `:nodeup` in <1s), a
  worker can move twice. Fine for most workloads; not for very expensive
  warm-up.
- **Cluster size.** Beautiful at 3–50 nodes. At 1000+ you'd want sharded rings
  or a different model — every node holding the full ring stops being free.
- **Membership view = ground truth.** libring is in-memory per node and assumes
  everyone sees the same membership. Diverged views = diverged placement =
  duplicate workers. Get your `libcluster` config right.

📊 **Diagram 9 — "When to use this"** *(optional, simple)*
- Two columns: ✅ "Reach for this" / ⚠️ "Reach for something else."
- ✅: long-lived stateful workers, per-tenant fan-out, WebSocket/subscription
  routing, heartbeating, sticky pollers.
- ⚠️: short jobs (use a queue), heavy GPU/data-locality (use placement
  constraints), 1000+ nodes (shard the ring), strict exactly-once (you need a
  log).

---

## Section 8 — Wrap (2 min)

- The whole scheduler is **~200 lines** because the runtime gave us cluster
  membership, monitoring, and `:erpc` for free.
- Compared to the Horde model: no extra infrastructure, no external
  coordination, fewer failure modes you have to model.
- Repo: github link. Slides + diagrams: link.

> **Speaker notes:** Close on the same image you opened with — the
> workload-landing diagram — but now with the ring overlaid and `:erpc` arrows
> showing the lookups. "These two primitives. That's the whole talk."

📊 **Diagram 10 — "Closing image (callback to Diagram 1)"**
- Re-show Diagram 1's nodes-and-workers, but with the ring from Diagram 6
  overlaid translucently in the background and small `:erpc` arrows where the
  question marks used to be.
- *Animation:* the question marks from the opener fade in, then dissolve into
  the ring + arrows. Lands the talk.

---

## Timing summary

| Section | Time | Notes |
|---|---:|---|
| 1. Problem | 5 |  |
| 2. Elixir alternatives (`:global`, Horde) | 6 |  |
| 3. Primitives + first demo | 8 | demo: `:erpc.multicall` against the dashboard |
| 4. libring + Horde comparison | 7 | comparison slide ends §4 |
| 5. Placement + scale demo | 6 | demo: spawn 50, scale 4→3→4 |
| 6. Zero-downtime + rolling demo | 6 | demo: rolling deploy + hard kill |
| 7. Caveats | 3 |  |
| 8. Wrap | 2 |  |
| **Subtotal** | **43** | |
| Q&A buffer | (your slot) | |
