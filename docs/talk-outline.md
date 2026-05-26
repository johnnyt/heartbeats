# Spreading Long-Running Workloads Across an Elixir Cluster
*Cluster membership, `:erpc`, and consistent hashing — the BEAM primitives, by example.*

**Total: ~43 min.** Audience: Elixir/BEAM folks, already bought in on the
runtime. We assume shared OTP intuition (processes, supervision, message
passing, `Node`/`:erpc`) and don't justify Elixir as a choice — the audience
already made it. This is a **teaching talk**: the goal is for the audience to
leave with a richer mental model of what the runtime *gives* them at the
cluster level, and to see one example (consistent-hashing placement via
libring) of composing those primitives into something useful. Prior-art
libraries (`:global`, Swarm, Horde) get a brief, respectful acknowledgement —
not a head-to-head. The Heartbeats demo is **woven through** sections 3–6.

---

## Section 1 — The Problem (6 min)

**Goal:** make the audience *feel* why placement matters before we touch a
single line of cluster code. The htop image does the work that abstract
bullet points won't.

### 1a. The shape of the workload

- **N long-running GenServers that each need a home** — Absinthe subscription
  heartbeats, Phoenix Channel sockets, per-tenant pollers, log tailers, "one
  worker per X" anything.
- Properties that make placement hard:
  - **Stateful** — round-robin at the LB doesn't help; the *process* is the
    state.
  - **Long-lived** — placement decisions stick for hours or days, not the
    milliseconds a task takes.
  - **Membership churn is the steady state, not an exception.** Nodes leave
    (deploys, autoscaling, crashes) and join (scale-up, restarts) constantly.

### 1b. The "one big node" failure mode

This is the new spine of §1. Show it before any solution.

🖼️ **Image 1 — "One core red, seven idle"**
- Real htop screenshot (or a faithful mock) of an 8-core box where one core is
  pegged at 100% (red bar, the runaway process) and the other seven are
  barely flickering at 2–5%.
- Caption underneath: ***"the workload is here. the capacity is over there."***

What's wrong with this picture — narrate over the image:

- **Resource waste.** You bought 8 cores and you're using 1. The other 7 are
  cooling the room.
- **Vertical-scale ceiling.** When that one core saturates, your only lever is
  a bigger box. You hit physics fast.
- **Head-of-line blocking.** Every tenant queues behind every other tenant's
  work on the same scheduler.
- **GC pauses are everyone's problem.** A heap blip on the busy node stalls
  every subscription it's hosting.
- **Blast radius = "everything".** That node dies (deploy, OOM, hardware) —
  every subscription dies with it. There's no surviving partial state to
  reconnect to.

> **Speaker notes:** Stay on the image. The room has all seen this picture in
> their own dashboards. Let it sit. The next 35 minutes are the answer to
> *"what would I rather see here?"* — and you'll show them that answer
> literally, with a callback htop image in §5.

### 1c. The two questions a cluster-native solution must answer

- **Which node runs the GenServer for key X?**
- **How does any other node send it a message?**

Both reduce to one: ***placement.*** Once you can answer "who owns X," `:erpc`
(or a `{name, node}` send) handles the rest — that's the next 35 minutes.

📊 **Diagram 1 — "The placement question"**
- Static frame: row of 4 nodes (matches the live demo cluster size), scattered
  worker dots colored by tenant.
- Two large arrows from a "register" cloud and a "talk to me" cloud, both with
  question marks pointing at the cluster.
- *Animation:* the question marks pulse; on click, they're replaced by a single
  "?" centered over the cluster — emphasizes that both questions reduce to one:
  *placement.*

> **Speaker notes:** This is the same `PlacementQuestion` component already in
> the deck. The htop image is the *visceral* version of the same question;
> Diagram 1 is the *abstract* version. They reinforce each other.

---

## Section 2 — Prior Art, Briefly (3 min)

**Goal:** name what already exists in this space, give the room enough to
calibrate, and move on. This is not a head-to-head. We're not justifying
libring against Horde — we're teaching the underlying primitives, and these
libraries are just other ways those primitives have been packaged.

### 2a. `:global` — the runtime's built-in cluster registry

```elixir
:global.register_name({:worker, sub_id}, self())
:global.whereis_name({:worker, sub_id})
```

- The runtime already tracks cluster membership; `:global` lets it track
  names too.
- One thing worth seeing once: under a netsplit, `:global`'s default
  conflict resolver **kills one of the duplicate processes when the
  partition heals.** Most teams meet this property in production.

📊 **Diagram 2 — "Name uniqueness, by murder"** *(existing
`GlobalRegisterRace` component — keep it; it's memorable and it's cheap)*
- Three nodes around the shared `:global` lock; netsplit; both partitions
  register the same name; heal; one pid gets a red strike.

> **Speaker notes:** This one slide earns its keep. Even people who've used
> `:global` for years often haven't met the netsplit behavior. After this,
> we move on — we are *not* spending five minutes on it.

### 2b. Swarm and Horde — frameworks built on top

One slide, two bullets:

- **Swarm** — handoff + an internal hash ring. Largely unmaintained, but its
  *idea* (place workers on a ring) is the one we'll build directly.
- **Horde** — distributed supervisor + CRDT-replicated registry. Actively
  maintained, real production usage. Owns the distribution lifecycle for you;
  good fit when you don't have a natural hash key or want explicit handoff
  hooks.

> **Speaker notes:** Be respectful and brief. Some of these maintainers are
> in the room. The point is acknowledgement, not comparison. *"These exist.
> They're built on the same runtime primitives we're about to look at. Today
> we're going to learn the primitives directly, and use libring as one
> example of composing them."*

---

## Section 3 — The Elixir Primitives (10 min, *demo woven in*)

**Goal:** the heart of the talk. The audience leaves this section knowing what
the BEAM hands them for free at the cluster level, with code on screen for
each. This is where we spend the time we saved by trimming §2.

### 3a. The cluster is a thing you can ask questions of

```elixir
Node.self()        #=> :"a@127.0.0.1"
Node.list()        #=> [:"b@127.0.0.1", :"c@127.0.0.1"]
```

- `Node.list()` is *not* a service-discovery API call. The runtime maintains
  cluster membership; you're reading a **local data structure**.
- That single fact is what makes everything downstream possible. Every node
  can answer "who's in the cluster?" in nanoseconds, with no coordination.

> **Speaker notes:** For folks coming from other ecosystems, "cluster
> membership" usually means a Consul/etcd/ZK round-trip. The BEAM doesn't
> work that way. This is the slide where that lands.

### 3b. `libcluster` — the discovery layer

```elixir
config :libcluster,
  topologies: [
    heartbeats: [strategy: Cluster.Strategy.LocalEpmd]
  ]
```

- One config block. `LocalEpmd` for the demo; `Kubernetes`, `Gossip`, or
  `DNSPoll` in prod. No discovery code in your application.
- libcluster handles the `Node.connect/1` calls. Once nodes are connected,
  `Node.list()` is populated and everything else in the talk works.

### 3c. `monitor_nodes` — the runtime tells you when membership changes

```elixir
:net_kernel.monitor_nodes(true)

# inbox now receives:
#   {:nodeup,   :"b@127.0.0.1"}
#   {:nodedown, :"b@127.0.0.1"}
```

Show a minimal GenServer skeleton — this is the pattern the audience will
see used three more times before the talk ends:

```elixir
defmodule MyApp.Watcher do
  use GenServer

  def init(state) do
    :net_kernel.monitor_nodes(true)
    {:ok, state}
  end

  def handle_info({:nodeup, node}, state)   do … end
  def handle_info({:nodedown, node}, state) do … end
end
```

- **Any GenServer can subscribe.** This is the foundation for automatic
  rebalance — and the same primitive libring uses internally.
- No registration ceremony. No callback hooks. Just messages in your inbox.

> **Speaker notes:** This slide is doing setup for §4 and §5 simultaneously.
> The audience will see this exact shape cash out twice in the next 15
> minutes. Plant the pattern now.

### 3d. `:erpc` — calling code on another node

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

Then point at the **Nodes** card on the dashboard — this is *exactly* what
`ClusterLive` does on every tick. The dashboard isn't talking to a service;
it's calling a function on three BEAMs in parallel.

📊 **Diagram 4 — "`:erpc` in one frame"**
- Two BEAM lozenges side by side, labeled `a@` and `b@`.
- *Animation step 1:* arrow from `a@` to `b@` labeled
  `:erpc.call(b, Mod, :fun, [arg])`.
- *Step 2:* `b@` runs the function (small spinner inside `b@`).
- *Step 3:* return-value arrow back to `a@`.
- Caption morph: **"no service discovery / no auth handshake / no JSON / no
  HTTP — just call a function."**

### 3e. (Aside) `:pg` exists too

One bullet, one slide, move on:

- `:pg` (process groups) is the other cluster primitive worth knowing —
  publish/subscribe to a group across nodes. Not what we need today
  (placement, not broadcast), but worth knowing it's there.

### 3f. Naïve placement, and why it's not enough

```elixir
def place(%Subscription{id: id} = sub) do
  owner = Enum.random([node() | Node.list()])
  :erpc.call(owner, WorkerSupervisor, :start_worker, [sub])
end
```

- Works… until a node leaves. The other nodes have no way to compute "what
  was on the dead one" without a registry — and we don't want a registry.
- We need a placement function that's **deterministic** (same key → same
  node) and **stable** (one membership change → small reassignment).

> **Speaker notes:** Cue the ring.

---

## Section 4 — Consistent Hashing & libring (7 min)

**Goal:** picture-first explanation of consistent hashing, then libring as
the four-line implementation. No framework comparison — just teach the
algorithm and show the code.

### 4a. Naive mod-N hashing breaks under membership changes

```elixir
Enum.at(nodes, :erlang.phash2(id, length(nodes)))
```

- Deterministic. Same key → same node. So far so good.
- Add a 4th node → ~75% of items move. Every membership change = mass
  migration. Deterministic, but not stable.

📊 **Diagram 5 — "Mod-N reshuffle"**
- Top: 3 columns (nodes), 12 colored dots distributed.
- *Animation:* a 4th column slides in; nearly every dot jumps column. Counter
  in the corner ticks **"reassigned: 9 / 12"**. Counter flashes red.

### 4b. The ring

📊 **Diagram 6 — "The hash ring"** *(centerpiece — six frames)*

The biggest visual in the deck. Build it in **six discrete frames**, each
held long enough to narrate. Use a single canvas; transitions between frames
are animated, not slide-cuts.

**Visual conventions:**
- Ring drawn as a thick gray circle, ~60% of slide height.
- Nodes are filled circles labeled `A`, `B`, `C` (and later `D`, `E`), each
  in a distinct hue (A=indigo, B=teal, C=amber, D=rose, E=emerald).
- Items are smaller dots, colorless until they "claim" an owner — then they
  inherit that owner's hue.
- An "ownership arc" is a translucent wedge of the owner's color, swept from
  the *previous* node clockwise to *that* node. An item's color is the color
  of the arc it sits in.

**Frame 1 — "Hash a key onto the ring."**
- Empty ring with one node `A` at 12 o'clock.
- One item dot `sub-42` flies in. Label: `hash("sub-42") = 0x8a91…`. Lands at
  its hashed position (say 4 o'clock).
- *"Every key — subscription id, tenant id, whatever — hashes to a point on
  the ring."*

**Frame 2 — "Walk clockwise to find the owner."**
- A small arrow grows clockwise from `sub-42` until it hits `A`. `sub-42`
  adopts A's indigo color.
- *"Walk clockwise. First node you hit owns the key."*

**Frame 3 — "Add nodes B, C, D; arcs appear."**
- `B`, `C`, `D` fade in. Four translucent arcs sweep into existence.
- 15 more items rain in (16 total). Each adopts the color of the arc it
  lands in. ~4 items per node.
- Counter: **"items: 16 · A:4 B:4 C:4 D:4"**.

**Frame 4 — "Add a 5th node. Watch what moves."**
- `E` fades in between `A` and `B`. New emerald arc carved out of A's indigo.
- Items in the new arc cross-fade indigo → emerald. The other three arcs
  briefly desaturate to call out that they *don't change.*
- Counter: **"reassigned: 1 / 16"**. Callout: ***"~1/N moves. Mod-N moved
  ~12/16."***

**Frame 5 — "Remove a node. Same property, in reverse."**
- `B` fades out (`:nodedown`). B's teal arc dissolves; its items cross-fade
  to C's amber. A, D, E arcs untouched.
- Counter: **"reassigned: 4 / 16"**.

**Frame 6 — "Zoom out: virtual nodes."**
- Camera zooms out; each node marker explodes into ~128 small marks scattered
  around the ring, color-coded to their owner.
- The arcs become *interleaved confetti* of all colors instead of four big
  wedges.
- *"Real ring libraries place each node ~128 times around the ring as
  'vnodes'. That's how the spread stays even — and when a node dies, its
  load redistributes across **every** survivor, not just one neighbor."*

> **Speaker notes:** The "only neighbors change" property is true for the
> no-vnode ring (Frames 1–5). With vnodes, every real node has segments
> scattered all around the ring, so a `:nodedown` redistributes across the
> whole cluster — but still ~1/N total items move. The live demo in §5 will
> show this directly: kill a node, watch all survivors take an even share.

### 4c. The two properties, one picture

- **Deterministic** — same key + same membership → same node, computed
  locally on every node, with no coordination.
- **Stable** — one membership change → ~1/N items move, not 75%.

### 4d. libring in 4 lines

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
  `:net_kernel.monitor_nodes/1` and updates the ring on `:nodeup` /
  `:nodedown` for you.
- That same primitive you saw in §3c, used internally by libring. **You
  never write membership-tracking code** — but you've now seen the same
  shape three times: a GenServer with `monitor_nodes(true)` in its init,
  reacting to inbox messages.
- Show `Heartbeats.Ring` (`lib/heartbeats/ring.ex`) — ~30 lines, four
  functions: `owner/1`, `members/0`, `cordon/1`, `uncordon/1`. The
  `cordon`/`uncordon` pair is the seed for §6.

> **Speaker notes:** The pedagogical payoff lands here. The audience saw
> `monitor_nodes` as a primitive in §3, then sees libring using it as the
> mechanism that keeps the ring in sync — same shape, no extra ceremony.

---

## Section 5 — Putting It Together: Placement (7 min, *demo woven in*)

**Goal:** the scheduler is three lines because the primitives did the work.
This is also where the htop callback pays off.

```elixir
def place(%Subscription{id: id} = sub) do
  owner = Ring.owner(id)
  :erpc.call(owner, WorkerSupervisor, :start_worker, [sub])
end
```

- **That's the scheduler.** No queue, no dispatcher, no coordinator.
- Walk through `Heartbeats.Placement` (`lib/heartbeats/placement.ex`):
  - One GenServer per node, locally named.
  - `init/1` calls `:net_kernel.monitor_nodes(true)`. *(Fourth time the
    audience has seen this shape. Call it out.)*
  - On `:nodeup` / `:nodedown` → `rebalance_local/0`.
  - `rebalance_local/0`: for each local worker, re-ask the ring; if the owner
    changed, `:erpc.cast` the new owner and stop the local copy.

```elixir
def handle_info({nodeevt, _node}, state) when nodeevt in [:nodeup, :nodedown] do
  rebalance_local()
  {:noreply, state}
end
```

- The **Worker** opts into its own migration on `:rebalance`. Each process is
  responsible for itself; no central mover yanks workers around. That's the
  BEAM-native shape.

🖥️ **Live demo (~2 min) — scale down, then back up** *(start at 4 nodes)*
1. In the dashboard, click **Spawn** with 50 subscriptions @ 5s.
2. Watch the **Subscriptions by node** cards even out (~12-13 per node).
3. Stop node `d`.
   - `:nodedown` propagates; ring redraws on every survivor.
   - Each survivor's count rebounds from ~12 → ~16 — *only ~1/4 of workers
     actually moved.*
4. Restart node `d`.
   - `:nodeup` propagates; workers redistribute back toward ~12-13 each.
5. The **callbacks received** counter never stops climbing.

🖼️ **Image 2 — "Eight cores, all working" (htop callback)**
- Side-by-side with Image 1 from §1. Left: the original "one red core, seven
  idle." Right: eight cores each at a healthy ~25–40%, no red.
- Caption: ***"same workload. same cores. just placed."***
- This is the visceral payoff of the whole talk. Hold it.

📊 **Diagram 7 — "`:nodedown` recovery"** — three frames
- *Frame 1:* 4 nodes A/B/C/D, workers as dots colored by ring zone.
- *Frame 2:* B vanishes. `:nodedown` envelopes fly in. Ring redraws: B's
  vnodes dissolve; A/C/D each absorb a slice.
- *Frame 3:* dotted arrows show orphaned workers being adopted on A, C, D
  roughly evenly. Counter: **total worker count: unchanged · moved: ~1/4**.

> **Speaker notes:** If the htop callback feels too on-the-nose, trust it
> anyway — the room remembers the §1 image. This is the moment the talk
> resolves its own opening tension. The "boring" recovery *is* the punch
> line.

---

## Section 6 — Zero-Downtime Deploys (6 min, *demo woven in*)

**Goal:** the payoff. Cordon/drain/uncordon falls out of the same primitives.

```elixir
def rolling_deploy(nodes) do
  for node <- nodes do
    Ring.cordon(node)              # remove from ring everywhere (:erpc fan-out)
    wait_until_drained(node)       # workers self-migrate; we just watch
    Ring.uncordon(node)            # re-add; trigger rebalance_local everywhere
    Process.sleep(@settle_ms)
  end
end
```

- **Cordon** = remove from the ring everywhere. Workers on the cordoned node
  see "I'm not the owner anymore" on their next `:rebalance` tick and
  `:erpc` themselves to the new owner.
- **Drain** = wait for the local worker count to hit zero. *No* central
  tracking; we're just polling `WorkerSupervisor`.
- **Uncordon** = put it back. New work re-spreads naturally.
- `Heartbeats.GracefulShutdown` — last child in the supervision tree, runs
  cordon + drain in `terminate/2`. A `kubectl rollout restart` looks
  identical to clicking the dashboard button.

🖥️ **Live demo (~2 min) — rolling deploy + hard kill** *(4-node cluster)*
1. Click **Rolling Deploy**. Talk over the ~20s rotation:
   - "Watch B's worker count hit zero — that's the drain."
   - "Watch A, C, and D absorb evenly — that's the ring."
   - "Watch the callbacks counter — that's the SLO."
2. In one iex: `Ctrl-C, a` to hard-kill node D.
3. `:nodedown` recovery in ~5s. Survivors pick up D's work.
4. Restart D → `:nodeup` → workers redistribute.

📊 **Diagram 8 — "Rolling deploy timeline"**
- Gantt-style: 4 horizontal lanes (A, B, C, D) over ~20s.
- Each lane has colored bands: **active (green) / cordoned (yellow) /
  draining (orange) / restarting (gray) / active (green)**.
- A worker-count line graph runs underneath, summed across live nodes.
- *Animation:* timeline plays left to right. The summed worker-count line is
  **flat the entire time** — that's the SLO promise.

> **Speaker notes:** The flat line is the whole talk in one image. If you
> only get one slide right, this is it.

---

## Section 7 — Caveats & When *Not* to Use This (2 min)

Earn trust by being honest about boundaries. Keep it short.

- **Workers must be placeable anywhere.** Anything pinned to a node (local
  file, GPU, attached disk) breaks the model.
- **Migration cost.** Workers in this demo are stateless between heartbeats;
  if yours have warm state, you need to checkpoint or accept a re-warm on
  migration.
- **Flap windows.** If a node bounces `:nodedown` → `:nodeup` in <1s, a
  worker can move twice. Fine for most workloads; not for expensive warm-up.
- **Cluster size.** Beautiful at 3–50 nodes. At 1000+ you'd want sharded
  rings — every node holding the full ring stops being free.
- **Membership view = ground truth.** libring assumes everyone sees the
  same membership. Diverged views → diverged placement → duplicate workers.
  Get your `libcluster` config right.
- **No natural hash key?** Reach for Horde — its distribution model fits
  better when any node can own the process.

📊 **Diagram 9 — "When to use this"** *(optional, simple)*
- Two columns: ✅ "Reach for this" / ⚠️ "Reach for something else."
- ✅: long-lived stateful workers, per-tenant fan-out, WebSocket/subscription
  routing, heartbeating, sticky pollers.
- ⚠️: short jobs (use a queue), heavy GPU/data-locality (use placement
  constraints), 1000+ nodes (shard the ring), strict exactly-once (use Horde
  or a log).

---

## Section 8 — Wrap (2 min)

- The whole scheduler is **~200 lines** because the runtime gave us cluster
  membership, monitoring, and `:erpc` for free.
- The shape you saw four times — a GenServer that calls
  `:net_kernel.monitor_nodes(true)` and reacts to `:nodeup` / `:nodedown` —
  is the entire "framework." There's no library between you and the runtime
  when something goes wrong at 3am.
- Repo: github link. Slides + diagrams: link.

> **Speaker notes:** Close on the same image you opened with — the
> workload-landing diagram — but now with the ring overlaid and `:erpc` arrows
> showing the lookups. *"These primitives. That's the whole talk."*

📊 **Diagram 10 — "Closing image (callback to Diagram 1)"**
- Re-show Diagram 1's nodes-and-workers, but with the ring from Diagram 6
  overlaid translucently and small `:erpc` arrows where the question marks
  used to be.

---

## Timing summary

| Section | Time | Notes |
|---|---:|---|
| 1. Problem + htop image | 6 | the "one red core" image lands here |
| 2. Prior art, briefly | 3 | `:global` murder slide, one Swarm/Horde slide |
| 3. Primitives + first demo | 10 | this is the headline section now |
| 4. Consistent hashing + libring | 7 | no framework comparison |
| 5. Placement + scale demo + htop callback | 7 | the second htop image pays off §1 |
| 6. Zero-downtime + rolling demo | 6 |  |
| 7. Caveats | 2 |  |
| 8. Wrap | 2 |  |
| **Subtotal** | **43** | |
| Q&A buffer | (your slot) | |
