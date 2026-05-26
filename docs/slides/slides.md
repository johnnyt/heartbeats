---
theme: seriph
title: Spreading Long-Running Workloads Across an Elixir Cluster
info: |
  Cluster membership, :erpc, and consistent hashing — the BEAM primitives, by example.
class: text-center
highlighter: shiki
lineNumbers: false
drawings:
  persist: false
transition: slide-left
mdc: true
fonts:
  sans: 'Inter'
  mono: 'JetBrains Mono'
---

# Spreading Long-Running Workloads Across an Elixir Cluster

<div class="mt-6 text-2xl opacity-80">
  Cluster membership, <code>:erpc</code>, and consistent hashing — the BEAM primitives, by example.
</div>

<div class="abs-bl mx-14 my-12 flex gap-2 opacity-60">
  <span>JohnnyT</span>
  <span>·</span>
  <span>github.com/JohnnyT/heartbeats</span>
</div>

<!--
Opening slide — name and repo on screen before they sit down.<br>
Audience: Elixir folks, already bought in. We're not justifying the runtime.<br>
This is a teaching talk: the goal is for the room to leave with a richer mental model of what the runtime gives them at the cluster level.
-->

---
layout: section
---

# 1. The Problem

<!--
6 minutes. Make them feel why placement matters before any solution.<br>
The htop image is doing the heavy lifting here — abstract bullets won't.
-->

---

# N long-running GenServers that each need a home

<v-clicks>

- Absinthe **subscription heartbeats**
- **LLM chat sessions** — per-conversation context
- **Agent loops** — tool-using agents holding state across turns
- Per-tenant **pollers**
- **Log tailers**
- "One worker per X" anything

</v-clicks>

<!--
Quick survey if it feels right: "who's reached for Horde? For :global? For Swarm?"<br>
90 seconds max — calibrates the room.
-->

---

# What makes placement hard

<div class="mt-6 space-y-5">

<div v-click>
  <div class="text-2xl font-semibold text-indigo-400">Stateful</div>
  <div class="mt-1 text-base opacity-85 leading-relaxed">
    The <em>process</em> is the state — its mailbox, its heap, its monitors. A normal load balancer routes any request to any healthy backend. Here, every message has to reach the specific process holding the conversation, on the specific node where it lives.
  </div>
</div>

<div v-click>
  <div class="text-2xl font-semibold text-teal-400">Long-lived</div>
  <div class="mt-1 text-base opacity-85 leading-relaxed">
    A web request is 50ms — placement is noise. A subscription runs until the user closes the tab. Every "where is <code>X</code>?" lookup has to keep answering correctly for hours or days, across thousands of unrelated cluster events.
  </div>
</div>

<div v-click>
  <div class="text-2xl font-semibold text-amber-400">Membership churn is the steady state</div>
  <div class="mt-1 text-base opacity-85 leading-relaxed">
    Deploys, autoscaling, spot reclamation, OOMs, hardware blips — nodes leave and join constantly. Every event triggers re-placement for the affected workers. If the placement layer can't redistribute <em>gracefully</em> on every one of those, you have an outage every time AWS hiccups.
  </div>
</div>

</div>

<!--
Each click adds one item. Don't rush — read the explanation aloud or paraphrase, then click.<br>
The third bullet is doing real work — it's the lens for both the scale-up/down demo (§5) and the rolling deploy demo (§6).<br>
When they see both demos behave the same way, they'll recognize it as the same property: membership churn → ring redistribution.
-->

---
layout: center
---

# The failure mode we're trying to avoid

<div class="mt-6 flex justify-center">
  <img src="/images/cores-one-maxed.png" alt="htop showing one CPU core pegged at 100% while the others sit idle" class="max-h-[55vh] rounded-lg shadow-lg" />
</div>

<div class="mt-6 text-xl text-amber-400 font-semibold">

The workload is here. The capacity is over there.

</div>

<!--
Stay on the image. The room has all seen this in their own dashboards.<br>
Let it sit before you start narrating the risks on the next slide.<br>
This image is the visceral version of "why placement matters" — and the §5 callback resolves it.
-->

---

# What's wrong with this picture

<div class="text-base opacity-80 mb-5 leading-relaxed max-w-4xl">

The image is <em>cores on one box</em> — but the same shape plays out at the <strong>cluster</strong> level. One node carrying all the work, the rest idle. The risks are the same.

</div>

<div class="space-y-3">

<div v-click class="flex gap-4 items-start">
  <div class="text-rose-400 text-2xl">⚠</div>
  <div>
    <div class="text-xl font-semibold">Resource waste</div>
    <div class="text-base opacity-80">You scaled to 8 nodes. You're using 1. The other 7 are warming the data centre.</div>
  </div>
</div>

<div v-click class="flex gap-4 items-start">
  <div class="text-rose-400 text-2xl">⚠</div>
  <div>
    <div class="text-xl font-semibold">No horizontal headroom</div>
    <div class="text-base opacity-80">Adding more nodes doesn't help — the workload doesn't spread to them. Your only lever is a bigger box for the one node doing the work, and physics catches up fast.</div>
  </div>
</div>

<div v-click class="flex gap-4 items-start">
  <div class="text-rose-400 text-2xl">⚠</div>
  <div>
    <div class="text-xl font-semibold">Head-of-line blocking</div>
    <div class="text-base opacity-80">Every tenant's traffic queues behind every other tenant's on the same node's schedulers.</div>
  </div>
</div>

<div v-click class="flex gap-4 items-start">
  <div class="text-rose-400 text-2xl">⚠</div>
  <div>
    <div class="text-xl font-semibold">Hiccups stall everyone on that node</div>
    <div class="text-base opacity-80">A GC pause, memory pressure, network blip — any wobble on the busy node stalls every subscription it's hosting.</div>
  </div>
</div>

<div v-click class="flex gap-4 items-start">
  <div class="text-rose-400 text-2xl">⚠</div>
  <div>
    <div class="text-xl font-semibold">Blast radius = "everything"</div>
    <div class="text-base opacity-80">That node dies (deploy, OOM, hardware) — every subscription it was hosting dies with it.</div>
  </div>
</div>

</div>

<!--
Open by reading the bridge sentence aloud: "The image is cores on one box, but the same shape plays out at the cluster level." Otherwise the audience reads the htop picture and thinks we're talking about intra-box scheduling.<br>
Five risks, each a click. Don't editorialize between them — let them stack.<br>
The room will be nodding by the third one. The fifth is the one that hurts: there's no surviving partial state to reconnect to.<br>
After this slide we pivot to the two questions a cluster-native solution must answer.
-->

---
clicks: 1
---

# Two questions

<PlacementQuestion :clicks="$clicks" class="mt-4" />

<!--
This is the thesis of the whole talk, told visually.<br>
<br>
Before clicking, narrate the two clouds:<br>
"A cluster-native solution has to answer two questions. One — which node runs the GenServer for key X? Two — how does any other node send it a message?"<br>
<br>
*click* — the two question marks dissolve into a single "?" labelled <strong>placement</strong>.<br>
<br>
"The first question IS placement. The second one falls out of it — once you know who owns X, the runtime makes sending a message trivial. The rest of the talk is teaching the primitives that answer that question."<br>
<br>
Don't name :erpc yet — §3 introduces it. Just gesture at "the runtime makes sending trivial" and let the click into §2 do the rest.
-->

---
layout: section
---

# 2. Prior Art, Briefly

<div class="text-xl opacity-70 mt-4">
  <code>:global</code>, Swarm, Horde — the Elixir prior art for this problem.
</div>

<!--
3 minutes total. Not a head-to-head. We're not justifying libring against Horde — we're teaching the underlying primitives, and these libraries are other ways those primitives have been packaged.<br>
Two slides: the :global murder slide (cheap and memorable), and one slide that names Swarm + Horde.
-->

---

# `:global` — the runtime's built-in cluster registry

```elixir
:global.register_name({:worker, sub_id}, self())
:global.whereis_name({:worker, sub_id})
#=> #PID<12345.678.0> or :undefined
```

<v-click>

<div class="mt-8 text-lg opacity-90 max-w-3xl">

The runtime already tracks cluster membership. <code>:global</code> lets it track names too.

</div>

</v-click>

<v-click>

<div class="mt-6 text-base opacity-80 max-w-3xl">

One thing worth seeing once: under a netsplit, <code>:global</code>'s default conflict resolver <strong>kills one of the duplicate processes when the partition heals</strong>.

</div>

</v-click>

<!--
Set up the netsplit beat. Even people who've used :global for years often haven't met this behavior.<br>
Next slide is the animation that makes it stick.
-->

---
clicks: 3
---

# Name uniqueness, by murder

<GlobalRegisterRace :clicks="$clicks" class="mt-2" />

<!--
Click sequence:<br>
0 — three nodes around the shared :global lock, three envelopes mid-flight<br>
1 — race resolved: A wins, B and C get {:error, :already_registered}<br>
2 — netsplit: lightning bolt, two partition locks, both register the same pid<br>
3 — heal: one pid survives, one is killed (red strike), caption appears<br>
<br>
Narrate as you click:<br>
"Three nodes try to register the same name simultaneously."<br>
*click* "One wins. The others get an error. So far, so okay."<br>
*click* "Now imagine a netsplit. Both partitions register locally — both succeed."<br>
*click* "Heal the partition. :global notices the conflict and… exits one of them."<br>
<br>
After this slide we are DONE with :global. Move on.
-->

---
layout: center
---

# Swarm and Horde — frameworks built on top

<div class="mt-8 grid grid-cols-2 gap-10 max-w-5xl mx-auto text-left">

<div>
  <div class="text-2xl font-semibold text-teal-400">Swarm</div>
  <div class="mt-3 text-base opacity-85 leading-relaxed">
    Handoff + an internal hash ring. Largely unmaintained — but the <em>idea</em> (place workers on a ring) is the one we'll build directly.
  </div>
</div>

<div>
  <div class="text-2xl font-semibold text-indigo-400">Horde</div>
  <div class="mt-3 text-base opacity-85 leading-relaxed">
    Distributed supervisor + CRDT-replicated registry. Actively maintained, real production usage. Owns the distribution lifecycle for you.
  </div>
</div>

</div>

<div v-click class="mt-12 text-xl text-amber-400 font-semibold max-w-3xl mx-auto">

These exist. They're built on the same runtime primitives we're about to look at. Today we're going to learn the primitives directly.

</div>

<!--
Be respectful and brief. Some of these maintainers are in the room.<br>
The point is acknowledgement, not comparison. Don't editorialize about tradeoffs.<br>
The "we're going to learn the primitives directly" line is the pivot into §3 — say it with intent.
-->

---
layout: section
---

# 3. The Elixir Primitives

<div class="text-xl opacity-70 mt-4">
  Cluster membership, <code>monitor_nodes</code>, <code>:erpc</code> — what the BEAM gives you for free.
</div>

<!--
10 minutes. The heart of the talk.<br>
The audience leaves this section knowing what the BEAM hands them for free at the cluster level, with code on screen for each.
-->

---
layout: center
---

# Membership

<div class="mt-4 text-xl opacity-70 italic">
  who's in the cluster, right now?
</div>

<!--
First sub-section of §3. Lighter than the top-level section dividers — this is a "we're switching topics" cue, not a section break. Pause for a beat before clicking on.
-->

---

# The cluster is a thing you can ask questions of

<div class="mb-4 text-base opacity-85 max-w-4xl leading-relaxed">

In most ecosystems, "who's in the cluster?" is a network round-trip — Consul, etcd, ZooKeeper. On the BEAM, it's a function call.

</div>

```elixir
Node.self()        #=> :"a@127.0.0.1"
Node.list()        #=> [:"b@127.0.0.1", :"c@127.0.0.1"]
```

<v-click>

<div class="mt-6 text-lg opacity-90 max-w-3xl">

<code>Node.list()</code> isn't an API call. The runtime maintains the membership; you're reading a <strong>local data structure</strong>.

</div>

</v-click>

<v-click>

<div class="mt-4 text-xl text-amber-400 font-semibold">

Every node answers in nanoseconds, with no coordination.

</div>

</v-click>

<!--
The bridge sentence above the code is doing real work — without it, the audience reads the Erlang code and doesn't register why it's surprising.<br>
This single fact (membership as local data) is what makes everything downstream possible.
-->

---

# `libcluster` — the discovery layer

```elixir
# config/runtime.exs
config :libcluster,
  topologies: [
    heartbeats: [
      strategy: Cluster.Strategy.LocalEpmd
    ]
  ]
```

<v-click>

<div class="mt-6 text-lg opacity-90">

Swap <code>LocalEpmd</code> for <code>Kubernetes</code>, <code>Gossip</code>, or <code>DNSPoll</code> in prod.

</div>

</v-click>

<v-click>

<div class="mt-4 text-xl text-amber-400">

One config block. No discovery code in your app.

</div>

</v-click>

<!--
libcluster handles the Node.connect/1 calls. Once nodes are connected, Node.list() is populated and everything else in the talk works.<br>
We won't think about discovery again in this talk.
-->

---
layout: center
---

# Lifecycle

<div class="mt-4 text-xl opacity-70 italic">
  runtime notification of changes
</div>

<!--
Second sub-section of §3. "Lifecycle" rather than "Monitoring" because the pattern (subscribe to runtime events, react in a GenServer) generalizes beyond monitor_nodes — trap_exit in §6 fits the same shape.
-->

---

# The runtime tells you when membership changes

```elixir
:net_kernel.monitor_nodes(true)

# inbox now receives:
#   {:nodeup,   :"b@127.0.0.1"}
#   {:nodedown, :"b@127.0.0.1"}
```

<v-click>

<div class="mt-6 text-lg opacity-90 max-w-3xl">

Any <code>GenServer</code> can subscribe. Just messages in your inbox — no registration ceremony, no callback hooks.

</div>

</v-click>

<!--
This is the primitive that does the most work in the rest of the talk.<br>
Don't dwell yet — the next slide shows the GenServer shape they'll see four more times.
-->

---

# The shape you'll see again

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

<v-click>

<div class="mt-6 text-lg opacity-90 max-w-3xl">

That's the entire "framework" for reacting to cluster membership.

</div>

</v-click>

<v-click>

<div class="mt-4 text-base opacity-75 max-w-3xl">

libring uses this shape internally. <code>Placement</code> uses it in §5. Same primitive doing the same job.

</div>

</v-click>

<!--
Plant the pattern now. The audience will see this exact shape in §5 (Placement) on a slide, and we'll reference libring using it internally in §4.<br>
By the time they see it in §5, they should recognize it as "the BEAM-native shape for cluster-aware code."
-->

---
layout: center
---

# RPC

<div class="mt-4 text-xl opacity-70 italic">
  call a function on another node
</div>

<!--
Third sub-section of §3. Frame it as "RPC" rather than ":erpc" so the audience hears it as a category (vs gRPC, Twirp, Thrift, etc.) before they see the Elixir-specific API. The gRPC contrast click reveal lands harder this way.
-->

---
clicks: 3
---

# `:erpc` in one frame

<ErpcInOneFrame :clicks="$clicks" class="mt-2" />

<!--
Click 0: two BEAM lozenges side by side, idle. a@ on the left (indigo stripe), b@ on the right (teal stripe).<br>
Click 1: amber call arrow appears from a@ → b@ along the top, labeled <code>:erpc.call(b, Mod, :fun, [arg])</code>.<br>
Click 2: b@ runs the function — small spinner appears inside b@, b@'s label flashes amber.<br>
Click 3: emerald return arrow appears from b@ → a@ along the bottom, labeled <code>{:ok, value}</code>. Caption fades in: "no service discovery · no auth handshake · no JSON · no HTTP — just call a function."<br>
<br>
Narrate: "Two BEAMs." *click* "Call a function on the other one." *click* "It runs there." *click* "You get the value back. That's it. No HTTP, no JSON, no service mesh — just call a function."<br>
<br>
The caption is the punchline — let it land on the final click.
-->

---

# `:erpc` — calling code on another node

```elixir
# Synchronous — returns a value or raises
:erpc.call(:"b@127.0.0.1", Heartbeats.WorkerSupervisor, :start_worker, [sub])
```

<v-click>

```elixir
# Fire-and-forget
:erpc.cast(node, Heartbeats.Placement, :rebalance_local, [])
```

</v-click>

<v-click>

```elixir
# Parallel fan-out, results keyed by node
:erpc.multicall([node() | Node.list()], Heartbeats.Placement, :stats, [])
```

</v-click>

<div v-click class="mt-6 text-base opacity-85 max-w-3xl">

Compare this to gRPC or any other RPC framework you've used. No <code>.proto</code> files. No code generation. No client/server scaffolding. No serializer config. Just a function reference and an argument list.

</div>

<!--
The gRPC comparison lands hard for folks who've spent days wiring up service contracts. Don't list the missing pieces too quickly — let each absence register.<br>
Build up progressively. Each click adds a variant.<br>
You will switch to terminal soon to run multicall live — flag that here so the audience is ready.<br>
The three variants matter for later: call (place a worker), cast (fire a rebalance), multicall (dashboard tick).
-->

---
layout: center
---

<div class="inline-block px-6 py-2 mb-6 rounded-full border-2 border-amber-400 text-amber-400 font-bold text-sm tracking-wider uppercase">
  Live demo · ~90 seconds
</div>

# Try it against the running cluster

```elixir
:erpc.multicall([node() | Node.list()], Heartbeats.Placement, :stats, [])
#=> [{:ok, %{worker_count: 0, node: :"a@127.0.0.1"}},
#    {:ok, %{worker_count: 0, node: :"b@127.0.0.1"}},
#    {:ok, %{worker_count: 0, node: :"c@127.0.0.1"}}]
```

<div class="mt-8 text-lg opacity-85 max-w-3xl mx-auto">

Then point at the <strong>Nodes</strong> card on the dashboard. This is <em>exactly</em> what <code>ClusterLive</code> does on every tick.

</div>

<div v-click class="mt-6 text-xl text-amber-400 font-semibold">

The dashboard isn't talking to a service. It's calling a function on three BEAMs in parallel.

</div>

<!--
Live demo — pre-staged iex session in the dashboard.<br>
Run multicall once with 0 workers, point at the Nodes card showing all green.<br>
If the demo gods are angry, fall back to a screenshot of the output. Don't fight it.<br>
The "calling a function on three BEAMs" line is the payoff — let it land.
-->

---

# Naïve placement

<div class="mb-4 text-base opacity-85 max-w-4xl leading-relaxed">

Three primitives — membership, lifecycle, RPC. Compose them and you get placement: <em>this</em> worker, on <em>that</em> node. Here is the first cut:

</div>

```elixir
def place(%Subscription{id: id} = sub) do
  owner = Enum.random([node() | Node.list()])
  :erpc.call(owner, WorkerSupervisor, :start_worker, [sub])
end
```

<v-click>

<div class="mt-8 text-lg opacity-90 max-w-3xl">

Works…

</div>

</v-click>

<v-click>

<div class="mt-2 text-xl text-rose-400 font-semibold max-w-3xl">

…until a node leaves. The other nodes have no way to compute <em>"what was on the dead one"</em> without a registry.

</div>

</v-click>

<v-click>

<div class="mt-6 text-base opacity-80 max-w-3xl">

And we don't want a registry. We want a placement <em>function</em>.

</div>

</v-click>

<!--
This is the pivot moment. Show the naïve code, let the room think "yeah okay so just use this," then break it on the second click.<br>
The third click sets up §4: we need a placement *function*, not a placement *service*.
-->

---

# What we actually need

<div class="mt-10 grid grid-cols-2 gap-8">

<div v-click>
  <div class="text-2xl font-semibold text-emerald-400">Deterministic</div>
  <div class="mt-3 text-lg opacity-85">Same key → same node, on every node, without coordination.</div>
</div>

<div v-click>
  <div class="text-2xl font-semibold text-emerald-400">Stable</div>
  <div class="mt-3 text-lg opacity-85">One membership change → small reassignment. Not ~75%.</div>
</div>

</div>

<div v-click class="mt-16 text-center text-2xl text-amber-400 font-semibold">

Consistent hashing delivers both.

</div>

<!--
This slide is the bridge into §4. The two requirements (deterministic + stable) are exactly what consistent hashing delivers.<br>
End on "cue the ring" with energy — the next 7 minutes are the heart of the talk.
-->

---
layout: section
---

# 4. Consistent Hashing & libring

<div class="text-xl opacity-70 mt-4">
  Placement as a pure function: same membership in, same node out.
</div>

<!--
7 minutes. Picture-first explanation, then libring as the implementation.<br>
No framework comparison — just teach the algorithm and show the code.
-->

---

# Naïve hashing: mod-N

```elixir
nodes = [node() | Node.list()]
Enum.at(nodes, :erlang.phash2(id, length(nodes)))
```

<v-click>

<div class="mt-8 text-lg opacity-90 max-w-3xl">

Deterministic. Same key → same node. So far, so good.

</div>

</v-click>

<v-click>

<div class="mt-4 text-xl text-rose-400 font-semibold max-w-3xl">

…until you add a 4th node. <strong>~75% of items move.</strong>

</div>

</v-click>

<v-click>

<div class="mt-4 text-base opacity-80 max-w-3xl">

Every membership change = mass migration. We have deterministic, but not stable.

</div>

</v-click>

<!--
Show the most obvious deterministic placement function. The audience will see it and think "wait, isn't that fine?" — then watch it fall over.<br>
The point is: deterministic alone isn't enough. We need deterministic AND stable.
-->

---
clicks: 1
---

# Mod-N reshuffle

<ModNReshuffle :clicks="$clicks" class="mt-2" />

<!--
Click 0: 3 columns, 12 items at their mod-3 slots (4 per column). Counter reads "12 · placed".<br>
Click 1: the 4th column slides in from the right. Items snap to their new mod-4 slots. The 9 items whose column changed flash with a rose ring. Counter alerts in rose: "reassigned: 9 / 12". Caption fades in: "deterministic ≠ stable."<br>
<br>
Narrate: "12 items, 3 columns, mod-N gives us a nice even spread. Now add a 4th column. Watch what moves."<br>
*click* "Nine of twelve. Deterministic — yes. Stable — no. That's what the ring fixes."
-->

---
layout: section
---

# The ring

<div class="text-xl opacity-70 mt-4">
  Same problem. Different topology.
</div>

<!--
Section divider so the audience knows we're switching modes — from "here's why mod-N is broken" to "here's the picture that fixes it."<br>
The next slide is the heaviest visual in the deck. Give it room.
-->

---
clicks: 6
---

# The hash ring

<HashRing :clicks="$clicks" class="mt-2" />

<!--
Seven frames, six clicks. Narrate as you advance:<br>
<br>
0 — Frame 1: "Every key — subscription id, tenant id, whatever — hashes to a point on the ring."<br>
*click* — Frame 2: "Walk clockwise. First node you hit owns the key. With one node, trivially everyone goes to A."<br>
*click* — Frame 3: "With four nodes, each owns the arc clockwise of its predecessor. Items inherit the arc's color."<br>
*click* — Frame 4: "Adding E only steals from its clockwise neighbor's arc. ~1/N moves. Mod-N moved ~12/16."<br>
*click* — Frame 5: "Now back to our 4-node baseline. This is the picture we started with."<br>
*click* — Frame 6: "Remove B. Same property, in reverse — only B's arc redistributes. 4 of 16 items move."<br>
*click* — Frame 7: "Real ring libraries place each node ~128 times around the ring as 'vnodes'. That's how the spread stays even — and when a node dies, its load redistributes across EVERY survivor."<br>
<br>
The vnode bridge to the live demo matters: §5's scale-down will show all three survivors picking up an even share of the dead node's work — that's vnodes earning their keep.
-->

---

# Why vnodes matter

<div class="mt-6 grid grid-cols-2 gap-6">

<div v-click>
  <div class="text-xl font-semibold text-rose-400">Without vnodes</div>
  <div class="mt-3 text-base opacity-85 leading-relaxed">
    Each node owns <strong>one big arc</strong>. When it dies, the entire arc transfers to its single clockwise neighbor.
  </div>
  <div class="mt-3 text-base opacity-85 leading-relaxed">
    That neighbor now carries <strong>2× its previous load.</strong> Everyone else: untouched.
  </div>
</div>

<div v-click>
  <div class="text-xl font-semibold text-emerald-400">With vnodes (~128 per node)</div>
  <div class="mt-3 text-base opacity-85 leading-relaxed">
    Each real node owns <strong>~128 tiny arcs</strong> scattered around the ring.
  </div>
  <div class="mt-3 text-base opacity-85 leading-relaxed">
    When it dies, those 128 arcs each fall to whoever's clockwise — statistically spread across <strong>every</strong> surviving real node.
  </div>
</div>

</div>

<div v-click class="mt-8 text-center text-xl text-amber-400 font-semibold max-w-3xl mx-auto">

Same "~1/N items move" property. Distributed evenly instead of dumped on one neighbor.

</div>

<v-click>

<div class="mt-6 text-sm opacity-70 max-w-3xl mx-auto text-center leading-relaxed">

Bonus: with 4 nodes placed randomly on the ring you might get clumping and uneven arcs. 4 × 128 = 512 marks always distribute smoothly. And if one box is beefier, give it 256 vnodes — it absorbs 2× the load.

</div>

</v-click>

<!--
The diagram showed the *what*; this slide explains the *why*.<br>
The key insight: without vnodes, a :nodedown is catastrophic for the single neighbor that inherits everything. With vnodes, it's a small bump for every survivor.<br>
The bonus paragraph (smoother spread, weighted capacity) is worth saying once but don't dwell — the main point is the failure-mode story.<br>
This sets up the §5 live demo: when we kill a node, all three survivors should pick up roughly equal slices. That's only true because of vnodes.
-->

---

# Two properties, one picture

<div class="mt-10 grid grid-cols-2 gap-8">

<div>
  <div class="text-2xl font-semibold text-emerald-400">Deterministic</div>
  <div class="mt-3 text-lg opacity-85">Same key + same membership → same node. Computed locally on every node.</div>
</div>

<div>
  <div class="text-2xl font-semibold text-emerald-400">Stable</div>
  <div class="mt-3 text-lg opacity-85">One membership change → ~1/N items move. Not 75%.</div>
</div>

</div>

<div v-click class="mt-16 text-center text-xl opacity-80 max-w-3xl mx-auto">

The mental model is done. Now — what does this look like in code?

</div>

<!--
A breather slide between the diagram and the library. The audience just absorbed a lot of motion; let the two properties settle before we show config.<br>
This is also the slide to point back at if anyone asks "wait, why again does this work?"
-->

---

# libring in 4 lines

```elixir
# config/config.exs
config :libring,
  rings: [heartbeats: [monitor_nodes: true, node_type: :visible]]
```

<v-click>

```elixir
HashRing.Managed.key_to_node(:heartbeats, subscription_id)
#=> :"b@127.0.0.1"
```

</v-click>

<v-click>

<div class="mt-6 text-lg opacity-90 max-w-3xl">

That's it. Config + a function call.

</div>

</v-click>

<!--
Beat after the diagram. Show the library as anticlimax — the audience just learned the algorithm; the code is small because the algorithm is small.
-->

---

# `monitor_nodes: true` — sound familiar?

```elixir
config :libring,
  rings: [heartbeats: [monitor_nodes: true, node_type: :visible]]
#                      ^^^^^^^^^^^^^^^^^^^
```

<v-click>

<div class="mt-8 text-lg opacity-90 max-w-3xl">

libring hooks <code>:net_kernel.monitor_nodes/1</code> internally. Same primitive you saw in §3.

</div>

</v-click>

<v-click>

<div class="mt-4 text-xl text-amber-400 font-semibold max-w-3xl">

By the time <em>your</em> code asks "who owns key X?", the ring is already correct.

</div>

</v-click>

<v-click>

<div class="mt-4 text-base opacity-75 max-w-3xl">

The GenServer shape from §3, used inside libring. You'll see it once more in your own code in §5.

</div>

</v-click>

<!--
This is where the pedagogical payoff lands. The audience saw the GenServer-with-monitor_nodes shape in §3; libring uses it internally; they'll see it once more in §5 (Placement) on a slide.<br>
Land "same primitive, same job, twice" — that's the talk's spine.
-->

---

# `Heartbeats.Ring` — a thin wrapper

```elixir
defmodule Heartbeats.Ring do
  def owner(key),   do: HashRing.Managed.key_to_node(:heartbeats, key)
  def members,      do: HashRing.Managed.nodes(:heartbeats)
  def cordon(node), do: HashRing.Managed.remove_node(:heartbeats, node)
end
```

<v-click>

<div class="mt-6 text-lg opacity-90 max-w-3xl">

<code>owner/1</code> is the only function placement code calls on the hot path.

</div>

</v-click>

<v-click>

<div class="mt-4 text-base opacity-75 max-w-3xl">

<code>cordon</code> is how we'll drive zero-downtime deploys in §6. Hold that thought.

</div>

</v-click>

<!--
Show the actual file — lib/heartbeats/ring.ex. It really is this short.<br>
The cordon hook is the seed for §6. Don't explain it yet; just plant it.<br>
The real module also exports uncordon/1, but we don't show it — in production a restarted pod is a new node (new BEAM, new name), so we never need to "uncordon" the same node back in. :nodeup handles it.
-->

---
layout: section
---

# 5. Putting It Together: Placement

<div class="text-xl opacity-70 mt-4">
  Three lines of scheduler. The primitives did the work.
</div>

<!--
7 minutes. The scheduler is three lines because §3 and §4 did the work.<br>
The htop callback at the end of this section is the visceral payoff of §1.
-->

---

# The whole scheduler

```elixir
def place(%Subscription{id: id} = sub) do
  owner = Ring.owner(id)
  :erpc.call(owner, WorkerSupervisor, :start_worker, [sub])
end
```

<v-click>

<div class="mt-8 text-xl text-amber-400 font-semibold max-w-3xl">

No queue. No dispatcher. No coordinator.

</div>

</v-click>

<v-click>

<div class="mt-4 text-base opacity-80 max-w-3xl">

Ask the ring who owns it. Call the function on that node. Done.

</div>

</v-click>

<!--
Let this slide breathe. The whole talk has been building to "and here's how short the actual code is."<br>
Three lines. Two of them are doing real work.
-->

---

# `Heartbeats.Placement` — the same shape, in your code

```elixir
defmodule Heartbeats.Placement do
  use GenServer

  def init(state) do
    :net_kernel.monitor_nodes(true)  # ← same shape from §3
    {:ok, state}
  end

  def handle_info({evt, _node}, state) when evt in [:nodeup, :nodedown] do
    rebalance_local()
    {:noreply, state}
  end
end
```

<v-click>

<div class="mt-4 text-lg opacity-90 max-w-3xl">

Same primitive libring uses internally. Same job, different consumer.

</div>

</v-click>

<!--
This is the payoff to the "you'll see this again" promise from §3.<br>
Same monitor_nodes(true) in init. Same handle_info for :nodeup/:nodedown.<br>
The point: it's the BEAM-native shape for "react to cluster membership" — libring uses it, your placement code uses it, same primitive doing the same job.
-->

---

# `rebalance_local` — workers self-migrate

```elixir
def rebalance_local do
  for {id, pid} <- WorkerSupervisor.local_workers() do
    case Ring.owner(id) do
      node when node == node() -> :ok               # still mine
      new_owner ->
        :erpc.cast(new_owner, WorkerSupervisor, :start_worker, [id])
        WorkerSupervisor.stop(pid)
    end
  end
end
```

<v-click>

<div class="mt-6 text-lg opacity-90 max-w-3xl">

Each worker decides for itself. No central mover. No coordinator yanking processes around.

</div>

</v-click>

<v-click>

<div class="mt-4 text-base opacity-75 max-w-3xl">

That's the BEAM-native shape: every process is responsible for itself.

</div>

</v-click>

<!--
The "each process responsible for itself" line is doing real work.<br>
It's why there's no convergence window, no handoff protocol, no central state — the cluster is decentralized because the workers are.
-->

---
clicks: 2
---

# `:nodedown` recovery

<NodedownRecovery :clicks="$clicks" class="mt-2" />

<!--
Walk through the diagram BEFORE the live demo — sets up what they're about to watch happen.<br>
Click 0: 4 nodes, 4 workers each (16 total). Counter: "workers: 16 · A:4 B:4 C:4 D:4".<br>
Click 1: B's card greys out and becomes dashed. <code>:nodedown</code> envelopes fan out from B to A/C/D. B's 4 workers float below B's old card, pulsing amber. Counter alerts in rose: ":nodedown — 4 workers orphaned".<br>
Click 2: orphan workers fly to A (2), C (1), D (1). Survivor counts bump (with a small scale-pulse on the count label) — A:6, C:5, D:5. Counter goes green: "workers: 16 · A:6 C:5 D:5 · moved: 4 / 16".<br>
<br>
Narrate: "Four nodes, sixteen workers." *click* "B dies. Every survivor hears :nodedown — the runtime tells them." *click* "B's four workers redistribute across the survivors. Total worker count: unchanged. Only ~1/4 moved."<br>
<br>
This is the SLO promise in miniature — same flat-total story as the rolling-deploy timeline in §6, just for one failure.
-->

---
layout: center
---

<div class="inline-block px-6 py-2 mb-6 rounded-full border-2 border-amber-400 text-amber-400 font-bold text-sm tracking-wider uppercase">
  Live demo · ~2 minutes
</div>

# Scale down, then back up

<div class="mt-6 text-left max-w-3xl mx-auto space-y-3 text-base">

1. **Spawn** 50 subscriptions @ 5s. Watch the cards even out (~12-13 per node).
2. **Stop node `d`.** <code>:nodedown</code> propagates; ring redraws on every survivor.
3. Each survivor's count rebounds from ~12 → ~16. <em class="text-amber-400">Only ~1/4 of workers moved.</em>
4. **Restart node `d`.** <code>:nodeup</code> → workers redistribute back toward ~12-13.
5. The **callbacks received** counter never stops climbing.

</div>

<!--
The audience just saw the cartoon version of this on the previous slide — now watch it happen for real.<br>
Run the demo against the 4-node cluster. The dashboard shows the worker count per node updating live.<br>
The point to land: only ~1/4 of workers actually moved. That's the ring's stability property in action.<br>
If the demo feels too fast in the room, run it twice. The "boring" recovery IS the punch line.
-->

---
layout: center
---

# Same workload. Same cores. Just placed.

<div class="mt-4 grid grid-cols-2 gap-6 max-w-6xl mx-auto items-center">

<div>
  <div class="text-sm uppercase tracking-wider text-rose-400 mb-2">Before</div>
  <img src="/images/cores-one-maxed.png" alt="One core pegged at 100%, seven idle" class="rounded-lg shadow-lg" />
</div>

<div>
  <div class="text-sm uppercase tracking-wider text-emerald-400 mb-2">After</div>
  <img src="/images/cores-evenly-spread.png" alt="Eight cores all working evenly" class="rounded-lg shadow-lg" />
</div>

</div>

<!--
THIS is the visceral payoff of the whole talk. Hold it.<br>
The §1 image resolves here. The audience has been waiting (without knowing it) for the right-hand picture since slide 6.<br>
Don't narrate over it — just let them see it. If you say anything, say: "same workload. same cores. just placed."<br>
This is the slide they'll remember in the hallway after the talk.
-->

---
layout: section
---

# 6. Zero-Downtime Deploys

<div class="text-xl opacity-70 mt-4">
  Cordon. Drain. The same primitives.
</div>

<!--
6 minutes. The payoff. Cordon + drain fall out of the same primitives we've been using.
-->

---

# Cordon. Drain.

<div class="mt-4 space-y-3 text-base max-w-4xl">

<div v-click><strong class="text-amber-400">Cordon</strong> — remove a node from the ring everywhere (<code>:erpc</code> fan-out). Workers on the cordoned node see "I'm not the owner anymore" on their next <code>:rebalance</code> tick.</div>

<div v-click><strong class="text-amber-400">Drain</strong> — wait for the local worker count to hit zero. <em>No central tracking;</em> just poll <code>WorkerSupervisor</code>.</div>

</div>

<div v-click class="mt-8 text-base opacity-85 max-w-4xl leading-relaxed">

A <code>kubectl rollout restart</code> sends SIGTERM to each pod in turn. The BEAM catches it, runs <code>GracefulShutdown.terminate/2</code>, cordons, drains, then exits. The replacement pod is a <em>new node</em> — it joins the cluster on startup, <code>:nodeup</code> fires everywhere, and the ring picks it up automatically. No orchestrator code.

</div>

<!--
This slide is conceptual — no Elixir code. Cordon + drain are built on Ring + :erpc; no new mechanism.<br>
No "uncordon" — in production, a restarted pod is a brand new BEAM node with a new name. It joins via libcluster, :nodeup fires, ring updates. Uncordon was only useful for the in-place demo where the same node comes back.<br>
The kubectl paragraph is what makes it real for the audience — they all know what a rollout restart is, and now they know what's happening inside their cluster when it fires. Sets up the GracefulShutdown slide that comes next.<br>
Speak the kubectl line slowly: SIGTERM → terminate/2 → cordon → drain → exit. New pod → :nodeup → ring updates.
-->

---
class: graceful-shutdown-slide
---

# `GracefulShutdown`: different hook, same idea

```elixir
defmodule Heartbeats.GracefulShutdown do
  use GenServer

  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  def terminate(_reason, _state) do
    Ring.cordon(node())
    Placement.rebalance_local()
    drain_until_empty()
  end
end
```

<div v-click class="mt-4 text-base opacity-90 max-w-3xl">

Last child in the supervision tree. <code>terminate/2</code> runs <em>before</em> the rest of the app stops.

</div>

<div v-click class="mt-3 text-base opacity-80 max-w-3xl">

<code>trap_exit</code> is a <em>process</em>-lifecycle hook; <code>monitor_nodes</code> is a <em>cluster</em>-lifecycle one. Different events, same idea: the runtime tells you when something changes — you just subscribe and react.

</div>

<!--
Say aloud: "kubectl rollout restart looks identical to clicking the dashboard button." Don't put it on the slide — the slide is already busy.<br>
Don't claim this is "the monitor_nodes shape again" — it's not. trap_exit is a different primitive (process lifecycle vs. cluster lifecycle).<br>
The honest framing is the broader pattern: the BEAM hands you lifecycle events; you subscribe and react. monitor_nodes and trap_exit are two instances of that.<br>
The fact that terminate/2 runs before children get stopped is the load-bearing detail — that's how we get to drain cleanly before shutdown.
-->

---
clicks: 1
---

# Rolling deploy timeline

<RollingDeployTimeline :clicks="$clicks" class="mt-2" />

<!--
Walk the audience through the predicted shape BEFORE the live demo — they'll know what to watch for when the dashboard does the real thing.<br>
<br>
Click once to start the sweep. The playhead crosses left-to-right over ~5 seconds.<br>
<br>
Watch each lane in turn: B cordons (yellow), drains (orange), restarts (gray), comes back active (green). Then C. Then D. Then A.<br>
<br>
The worker-count line at the bottom stays FLAT. That's the SLO. That's the punchline.<br>
<br>
Narration: "Watch the line at the bottom. Lanes change color — work is moving. But the total worker count never moves. That's the whole talk in one image."<br>
<br>
If you want to replay, just navigate away and back. The animation re-fires on slide entry.
-->

---
layout: center
---

<div class="inline-block px-6 py-2 mb-6 rounded-full border-2 border-amber-400 text-amber-400 font-bold text-sm tracking-wider uppercase">
  Live demo · ~2 minutes
</div>

# Rolling deploy + hard kill

<div class="mt-6 text-left max-w-3xl mx-auto space-y-3 text-base">

1. Click **Rolling Deploy**. Talk over the ~20s rotation:
   - "Watch B's worker count hit zero — that's the drain."
   - "Watch A, C, and D absorb evenly — that's the ring."
   - "Watch the callbacks counter — that's the SLO."
2. In one iex: <code>Ctrl-C, a</code> to hard-kill node D.
3. <code>:nodedown</code> recovery in ~5s. Survivors pick up D's work.
4. Restart D → <code>:nodeup</code> → workers redistribute.

</div>

<!--
The audience just saw the predicted timeline (flat worker-count line). Now show them the real dashboard doing the same thing.<br>
Two demos in one: graceful rotation, then violent failure. Both look identical from the dashboard's perspective.<br>
The callbacks counter is the SLO — its uninterrupted climb is the whole point.
-->

---
layout: section
---

# 7. Caveats

<!--
2 minutes. Earn trust by being honest about boundaries. Keep it short.
-->

---

# When *not* to reach for this

<div class="mt-4 space-y-3">

<div v-click class="flex gap-3 items-start">
  <div class="text-rose-400 text-xl">⚠</div>
  <div>
    <div class="font-semibold">Workers pinned to a node</div>
    <div class="text-sm opacity-75">Local file, GPU, attached disk — breaks the model.</div>
  </div>
</div>

<div v-click class="flex gap-3 items-start">
  <div class="text-rose-400 text-xl">⚠</div>
  <div>
    <div class="font-semibold">Expensive warm-up state</div>
    <div class="text-sm opacity-75">If workers are stateful between events, you need to checkpoint or accept re-warm on migration.</div>
  </div>
</div>

<div v-click class="flex gap-3 items-start">
  <div class="text-rose-400 text-xl">⚠</div>
  <div>
    <div class="font-semibold">Flap windows</div>
    <div class="text-sm opacity-75">If a node bounces <code>:nodedown</code> → <code>:nodeup</code> in &lt;1s, a worker can move twice.</div>
  </div>
</div>

<div v-click class="flex gap-3 items-start">
  <div class="text-rose-400 text-xl">⚠</div>
  <div>
    <div class="font-semibold">Cluster size at 1000+ nodes</div>
    <div class="text-sm opacity-75">Every node holding the full ring stops being free. Shard the ring or use a different model.</div>
  </div>
</div>

<div v-click class="flex gap-3 items-start">
  <div class="text-rose-400 text-xl">⚠</div>
  <div>
    <div class="font-semibold">Diverged membership views</div>
    <div class="text-sm opacity-75">libring assumes everyone sees the same membership. Get your <code>libcluster</code> config right.</div>
  </div>
</div>

</div>

<!--
Five caveats, one click each. Don't dwell — the room knows you're being honest.<br>
These are honest boundaries of placement-by-hash; we're not steering anyone to a different library here.
-->

---
layout: section
---

# 8. Wrap

---

# What we built

<div class="mt-8 space-y-6">

<div v-click>
  <div class="text-2xl font-semibold text-emerald-400">~200 lines of application code</div>
  <div class="mt-2 text-base opacity-80">The runtime gave us cluster membership, monitoring, and <code>:erpc</code> for free.</div>
</div>

<div v-click>
  <div class="text-2xl font-semibold text-emerald-400">One primitive, two consumers</div>
  <div class="mt-2 text-base opacity-80">A GenServer that calls <code>:net_kernel.monitor_nodes(true)</code> and reacts to <code>:nodeup</code> / <code>:nodedown</code>. libring uses it. <code>Placement</code> uses it. Same primitive, same job.</div>
</div>

<div v-click>
  <div class="text-2xl font-semibold text-emerald-400">No library between you and the runtime</div>
  <div class="mt-2 text-base opacity-80">When something goes wrong at 3am, the whole stack is in your codebase.</div>
</div>

</div>

<!--
The three things to leave the room with.<br>
The middle one — "one shape, four times" — is the pedagogical takeaway. The audience has now seen monitor_nodes used four times in the talk; if they remember nothing else, they remember the shape.
-->

---
clicks: 1
---

# Two answers

<ClosingImage :clicks="$clicks" class="mt-2" />

<!--
Click 0: the opener's exact picture — two clouds (register? / talk to me?), arrows to the cluster, two pulsing question marks. Same image they saw 40 minutes ago.<br>
Click 1: the question marks fade. The ring overlay materializes around the cluster (translucent amber stroke + vnode confetti). The arrow labels become <code>:erpc.call</code> and <code>Ring.owner/1</code>. Caption fades in: "these primitives — that's the whole talk."<br>
<br>
Narrate: "Forty minutes ago I asked: which node runs the GenServer for X, and how does any other node send it a message?" *pause* *click* "Ring.owner answers the first question. :erpc answers the second. That's the whole talk."<br>
<br>
Hold the final frame while you say thanks.
-->

---
layout: center
class: text-center
---

# Thanks

<div class="mt-8 text-xl opacity-80 space-y-2">

<div>github.com/JohnnyT/heartbeats</div>
<div>slides + diagrams: link</div>

</div>

<div class="mt-12 text-2xl text-amber-400 font-semibold">

These primitives. That's the whole talk.

</div>

<!--
The closing line. Same shape, every time.
-->
