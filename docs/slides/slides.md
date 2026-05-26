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
[Pre-flight: mic check, demo cluster running, dashboard tab open, iex pre-staged for §3.]

[As people settle, slide is up with name and repo URL. Don't start yet — give them a beat to read it.]

[When ready:]
"This is a talk about spreading long-running workloads across an Elixir cluster — by way of cluster membership, :erpc, and consistent hashing."

[Brief pause, then advance.]

[Budget: ~43 min talk + Q&A buffer.]
-->

---
layout: section
---

# 1. The Problem

<!--
[Say:]
"Section one — the problem. Before any solutions, let's anchor in why placement is hard."

[Pause. Advance.]

[Budget: ~6 min through end of §1.]
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
[Say:]
"This talk is about long-running GenServers that each need a home. A few shapes that fit:"

[Click through each, naming briefly. Don't dwell.]

[click]
Absinthe heartbeats — the workload that drives Heartbeats.

[click]
LLM chat sessions — per-conversation context.

[click]
Agent loops — tool-using agents holding state across turns.

[click]
Per-tenant pollers.

[click]
Log tailers.

[click]
"One worker per X" anything.

[Optional show-of-hands, only if it feels right:]
"Quick show of hands — who's reached for Horde for something like this? For :global? Swarm? A homegrown registry?"

[90 seconds max. Move on.]
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
[Open:]
"Three properties make placement hard."

[click]
Stateful — talk about how the process IS the state (its mailbox, its heap). Contrast with a normal LB: it routes requests to any healthy backend. Here, the message has to land on the specific node running the specific process.

[click]
Long-lived — contrast 50ms web requests (placement is noise) vs hours-long subscriptions. Decisions stick across thousands of unrelated cluster events.

[click]
Membership churn — the third one carries the most weight. Talk about how churn is the steady state, not an exception: deploys, autoscaling, spot reclamation, OOMs, hardware. Each event triggers re-placement.

[Pause after the third click. Let "outage every time AWS hiccups" land — it's the lens for the demos in §5 and §6.]
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
[Silence for a beat — let the image land. Everyone in the room has seen this in their own dashboards.]

[Then read the caption aloud, slowly:]
"The workload is here. The capacity is over there."

[Pause again. Don't pivot to the risks yet — that's the next slide. This image is the visceral version of the problem; §5 has the resolved version.]
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
[Read the bridge sentence aloud, slowly:]
"The image is cores on one box — but the same shape plays out at the cluster level. One node carrying all the work, the rest idle. The risks are the same."

[Pause. Make sure the framing transfers before clicking.]

[click]
Resource waste — paid for 8, using 1.

[click]
No horizontal headroom — more nodes don't help if work doesn't spread.

[click]
Head-of-line blocking — every tenant queued behind every other.

[click]
Hiccups stall everyone on that node — GC, memory pressure, network blips.

[click]
Blast radius — node dies, every subscription it was hosting dies.

[The fifth is the one that hurts. Don't tack on commentary — let the silence land it. Then advance.]
-->

---
clicks: 1
---

# Two questions

<PlacementQuestion :clicks="$clicks" class="mt-4" />

<!--
[Before clicking, gesture at the two clouds and say:]
"A cluster-native solution has to answer two questions. One: which node runs the GenServer for key X? Two: how does any other node send it a message?"

[Pause briefly.]

[click]
"The first question IS placement. The second one falls out of it — once you know who owns X, the runtime makes sending a message trivial. The rest of the talk is the primitives that answer that question."

[Pause. This is the thesis of the whole talk. Then advance into §2.]

[Don't name :erpc yet — §3 introduces it. Just gesture at "the runtime makes sending trivial."]
-->

---
layout: section
---

# 2. Prior Art, Briefly

<div class="text-xl opacity-70 mt-4">
  <code>:global</code>, Swarm, Horde — the Elixir prior art for this problem.
</div>

<!--
[Say:]
"Section two — the Elixir prior art for this problem, briefly. We're not comparing libraries today — we're going to learn the primitives underneath them."

[Pause. Advance.]

[Budget: ~3 min through end of §2. This section is deliberately short.]
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
[Say:]
":global — the runtime ships with a built-in cluster registry."

[Let them read the code for a beat.]

[click]
Talk about how :global lets the runtime track names alongside membership. It's the natural first reach for cross-node naming.

[click]
"One thing worth seeing once: when a netsplit heals, :global's default conflict resolver kills one of the duplicate processes. Most people who've used :global for years haven't met this behavior — the next slide shows it."

[Advance.]
-->

---
clicks: 3
---

# Name uniqueness, by murder

<GlobalRegisterRace :clicks="$clicks" class="mt-2" />

<!--
[Diagram tells the story; you narrate the beats.]

[Say before clicking:]
"Three nodes try to register the same name simultaneously."

[click]
"One wins. The others get an error. So far, so okay."

[click]
"Now imagine a netsplit. Both partitions register locally — both succeed."

[click]
"Heal the partition. :global notices the conflict and… exits one of them."

[Brief pause for the punchline to land. Then advance.]

[After this slide we're done with :global — don't loop back.]
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
[Read both columns aloud — they're short. Be respectful; some of these maintainers may be in the room.]

[Say:]
"Swarm — handoff plus an internal hash ring. Largely unmaintained, but the idea — placing workers on a ring — is the one we'll build directly."

"Horde — distributed supervisor plus a CRDT-replicated registry. Actively maintained, real production usage. Owns the distribution lifecycle for you."

[click]
"These exist. They're built on the same runtime primitives we're about to look at. Today we're going to learn the primitives directly."

[Say that last sentence with intent — it's the pivot into §3. Advance.]
-->

---
layout: section
---

# 3. The Elixir Primitives

<div class="text-xl opacity-70 mt-4">
  Cluster membership, <code>monitor_nodes</code>, <code>:erpc</code> — what the BEAM gives you for free.
</div>

<!--
[Say:]
"Section three — the Elixir primitives. Three things the BEAM hands you for free: who's in the cluster, when that changes, and how to call a function on another node."

[Pause. Advance.]

[Budget: ~10 min through end of §3. The heart of the talk.]
-->

---
layout: center
---

# Membership

<div class="mt-4 text-xl opacity-70 italic">
  who's in the cluster, right now?
</div>

<!--
[Brief pause to register the topic switch.]

[Say:]
"Membership — who's in the cluster, right now?"

[Advance.]
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
[Read the bridge sentence aloud, slowly:]
"In most ecosystems, 'who's in the cluster?' is a network round-trip — Consul, etcd, ZooKeeper. On the BEAM, it's a function call."

[Pause while they read the two lines of code.]

[click]
"Node.list isn't an API call. The runtime maintains the membership; you're reading a local data structure."

[click]
"Every node answers in nanoseconds, with no coordination."

[Pause. Let "no coordination" land — this is the fact the next 30 minutes builds on.]
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
[Say:]
"libcluster — the discovery layer. One config block."

[Let them read the config.]

[click]
"Swap LocalEpmd for Kubernetes, Gossip, or DNSPoll in prod."

[click]
"One config block. No discovery code in your app."

[Move on — we don't think about discovery again in this talk.]
-->

---
layout: center
---

# Lifecycle

<div class="mt-4 text-xl opacity-70 italic">
  runtime notification of changes
</div>

<!--
[Brief pause.]

[Say:]
"Lifecycle — the runtime tells you when membership changes."

[Advance.]
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
[Say:]
"One line of Erlang turns this on."

[Let them read the code. Walk through the inbox messages briefly.]

[click]
"Any GenServer can subscribe. Just messages in your inbox — no registration ceremony, no callback hooks."

[Don't dwell — the next slide shows the GenServer shape they'll see again.]
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
[Read the title aloud:]
"This is the shape you'll see again — twice more, actually."

[Walk through the code briefly: init calls monitor_nodes, handle_info catches :nodeup / :nodedown.]

[click]
"That's the entire 'framework' for reacting to cluster membership."

[click]
"libring uses this shape internally. Placement uses it in §5. Same primitive doing the same job."

[Plant the pattern — they'll recognize it when it returns.]
-->

---
layout: center
---

# RPC

<div class="mt-4 text-xl opacity-70 italic">
  call a function on another node
</div>

<!--
[Brief pause.]

[Say:]
"RPC — call a function on another node. You've seen this idea before — gRPC, Twirp, whatever. The BEAM's version is going to look surprisingly small."

[Advance.]
-->

---
clicks: 3
---

# `:erpc` in one frame

<ErpcInOneFrame :clicks="$clicks" class="mt-2" />

<!--
[Say:]
"Two BEAMs."

[click]
"Call a function on the other one."

[click]
"It runs there."

[click]
"You get the value back. That's it. No HTTP, no JSON, no service mesh — just call a function."

[Let the punchline land. Then advance.]
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
[Say:]
"Three variants — same shape. Call: synchronous. Returns a value or raises."

[click]
"Cast: fire-and-forget. Used for things like 'rebalance yourself.'"

[click]
"Multicall: parallel fan-out across the cluster, results keyed by node. We'll run this one live in a moment."

[click]
"Compare this to gRPC or any other RPC framework you've used. No .proto files. No code generation. No client/server scaffolding. No serializer config. Just a function reference and an argument list."

[Don't rattle through the missing pieces — let each absence register, especially with the backend folks in the room.]
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
[Pre-flight: iex pre-staged in the dashboard's iex tab. 4 nodes connected. Workers = 0.]

[Say:]
"I'm going to run that multicall live."

[Switch to terminal. Run:]
:erpc.multicall([node() | Node.list()], Heartbeats.Placement, :stats, [])

"Three nodes. All zero workers. One function call."

[Switch back to dashboard. Hover the Nodes card.]
"This card on the dashboard runs that exact call on every tick."

[click]
"The dashboard isn't talking to a service. It's calling a function on three BEAMs in parallel."

[Let it land. Advance.]

[Failure mode: if iex is dead, show a pre-captured screenshot. Say "trust the previous run — the output is the same" and move on.]
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
[Read the bridge aloud:]
"Three primitives — membership, lifecycle, RPC. Compose them and you get placement: this worker, on that node. Here is the first cut:"

[Let them read the code. It's short.]

[click]
"Works…"

[Brief pause — let the room think "yeah, okay."]

[click]
"…until a node leaves. The other nodes have no way to compute 'what was on the dead one' without a registry."

[click]
"And we don't want a registry. We want a placement function."

[Brief pause. This sets up §4. Advance.]
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
[click]
"Same key → same node, on every node, without coordination."

[click]
"One membership change → small reassignment. Not 75%."

[click]
"Consistent hashing delivers both."

[End with energy — the next 7 minutes are the heart of the talk. Advance.]
-->

---
layout: section
---

# 4. Consistent Hashing & libring

<div class="text-xl opacity-70 mt-4">
  Placement as a pure function: same membership in, same node out.
</div>

<!--
[Say:]
"Section four — consistent hashing, and the libring library that gives us placement as a pure function."

[Pause. Advance.]

[Budget: ~7 min through end of §4. Picture-first, then four lines of code.]
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
[Say:]
"The simplest deterministic placement function is mod-N. Let's see if it works."

[Let them read the two lines of code.]

[click]
"Deterministic. Same key → same node. So far, so good."

[click]
"…until you add a 4th node. About 75% of items move."

[click]
"Every membership change is a mass migration. Deterministic — yes. Stable — no."

[Set up the next slide: a visual that makes this concrete.]
-->

---
clicks: 1
---

# Mod-N reshuffle

<ModNReshuffle :clicks="$clicks" class="mt-2" />

<!--
[Say:]
"Twelve items, three columns. Mod-N gives us a nice even spread. Now add a 4th column. Watch what moves."

[click]
"Nine of twelve. That's what the ring fixes."

[Advance.]
-->

---
layout: section
---

# The ring

<div class="text-xl opacity-70 mt-4">
  Same problem. Different topology.
</div>

<!--
[Brief pause for the topic shift.]

[Say:]
"The ring — same problem, different topology."

[Advance. Next slide is the heaviest visual in the deck. Give it room.]
-->

---
clicks: 6
---

# The hash ring

<HashRing :clicks="$clicks" class="mt-2" />

<!--
[Say:]
"Every key — subscription id, tenant id, whatever — hashes to a point on the ring."

[click]
"Walk clockwise. First node you hit owns the key. With one node, everyone goes to A."

[click]
"With four nodes, each owns the arc clockwise of its predecessor. Items inherit the arc's color."

[click]
"Adding E only steals from its clockwise neighbor's arc. About 1/N moves. Mod-N moved 12 of 16."

[click]
"Now back to our 4-node baseline. This is the picture we started with."

[click]
"Remove B. Same property in reverse — only B's arc redistributes. Four of sixteen items move."

[click]
"Real ring libraries place each node about 128 times around the ring — 'vnodes.' That's how the spread stays even, and when a node dies, its load redistributes across EVERY survivor, not just one neighbor."

[The vnode bridge to the live demo matters: §5's scale-down shows all three survivors picking up an even share. That's vnodes earning their keep.]
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
[The diagram showed the WHAT; this slide explains the WHY.]

[click]
"Without vnodes, each node owns one big arc. When it dies, the entire arc transfers to its single clockwise neighbor — that neighbor now carries 2× its previous load. Everyone else: untouched."

[click]
"With ~128 vnodes per real node, those arcs are scattered around the ring. When a node dies, its 128 arcs each fall to whoever's clockwise — statistically across every surviving real node."

[click]
"Same one-over-N items move. Distributed evenly instead of dumped on one neighbor."

[click]
"Bonus — vnodes smooth out random placement, and you can give a beefier box 256 vnodes for 2× the load."

[Don't dwell on the bonus. The failure-mode story is the main point.]
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
[Walk through both briefly:]
"Two properties. Deterministic — same key plus same membership equals same node, on every node, locally. Stable — one membership change moves about one-over-N items, not 75%."

[click]
"The mental model is done. Now — what does this look like in code?"

[A breather slide between the diagram and the library — point back here if anyone later asks "wait, why does this work?" Advance.]
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
[Say:]
"libring. Here's the config — turn on monitor_nodes, name the ring."

[click]
"And here's the lookup. HashRing.Managed.key_to_node, ring name, key. Returns the owner node."

[click]
"That's it. Config plus a function call."

[The library is anticlimax — they just learned the algorithm; the code is small because the algorithm is small. Advance.]
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
[Say:]
"Notice this flag — sound familiar?"

[click]
"libring hooks net_kernel.monitor_nodes internally. Same primitive you saw in §3."

[click]
"By the time YOUR code asks 'who owns key X?', the ring is already correct."

[click]
"The GenServer shape from §3, used inside libring. You'll see it once more in your own code in §5."

[Land "same primitive, same job, twice" — that's the talk's spine. Advance.]
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
[Say:]
"This is the actual Heartbeats.Ring module from the codebase. Three functions of meaningful code — owner wraps key_to_node, members wraps nodes, cordon wraps remove_node."

[click]
"owner is the only function placement code calls on the hot path."

[click]
"cordon is how we'll drive zero-downtime deploys in §6. Hold that thought."

[The cordon hook is the seed for §6 — don't explain it yet; just plant it. Advance.]

[The real module also exports uncordon/1, but we don't show it: in production a restarted pod is a new node (new BEAM, new name), so :nodeup handles re-adding. If asked, that's the answer.]
-->

---
layout: section
---

# 5. Putting It Together: Placement

<div class="text-xl opacity-70 mt-4">
  Three lines of scheduler. The primitives did the work.
</div>

<!--
[Say:]
"Section five — putting it together. Placement is three lines because §3 and §4 did all the work."

[Pause. Advance.]

[Budget: ~7 min through end of §5. The htop callback at the end is the visceral payoff of §1.]
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
[Let them read the three lines.]

[Say:]
"That's the entire scheduler. Three lines."

[click]
"No queue. No dispatcher. No coordinator."

[click]
"Ask the ring who owns it. Call the function on that node. Done."

[Let this slide breathe. The whole talk has been building to "and here's how short the actual code is." Advance.]
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
[Say:]
"Placement is a GenServer. init calls monitor_nodes. handle_info reacts to :nodeup and :nodedown by calling rebalance_local."

"This is the GenServer shape from §3 — the one libring uses internally. Now in YOUR code."

[click]
"Same primitive, same job, different consumer."

[Land the payoff to the §3 promise. Advance.]
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
[Walk through the code:]
"For each local worker, ask the ring who owns it. If we're still the owner, do nothing. Otherwise, RPC the new owner to start a replacement, then stop ourselves."

[click]
"Each worker decides for itself. No central mover. No coordinator yanking processes around."

[click]
"That's the BEAM-native shape — every process is responsible for itself."

[This is why there's no convergence window, no handoff protocol, no central state — the cluster is decentralized because the workers are. Advance.]
-->

---
clicks: 2
---

# `:nodedown` recovery

<NodedownRecovery :clicks="$clicks" class="mt-2" />

<!--
[Walk through the diagram BEFORE the live demo — sets up what they're about to watch happen.]

[Say:]
"Four nodes, sixteen workers."

[click]
"B dies. Every survivor hears :nodedown — the runtime tells them."

[click]
"B's four workers redistribute across the survivors. Total worker count: unchanged. Only one-over-N moved."

[This is the SLO promise in miniature — same flat-total story as §6's rolling-deploy timeline, just for one failure. Advance.]
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
[Pre-flight: 4-node cluster running, dashboard open, all nodes connected, callbacks counter visible.]

[Say:]
"The audience just saw the cartoon. Now watch it happen for real."

[Demo (~2 min):]

1. Click Spawn (50 subscriptions @ 5s). Watch the cards even out.
   "Fifty subscriptions, spread evenly. Roughly twelve or thirteen per node."

2. Stop node d.
   "Stop d. Watch the survivors — they each absorb a slice."

3. Survivor counts rebound ~12 → ~16.
   "About one-quarter of the workers moved. The other three-quarters stayed put."

4. Restart node d.
   "Bring d back. Workers redistribute back toward even."

5. Point at the callbacks-received counter.
   "And the callbacks counter never stopped climbing — the SLO held the whole time."

[The "boring" recovery IS the punch line. If demo feels too fast, run it twice.]

[Failure mode: if a node won't come back up, skip step 4. The scale-down half is the load-bearing one.]
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
[Hold the silence. This is the visceral payoff of the whole talk — §1's htop image, resolved.]

[If you say anything, just read the title aloud:]
"Same workload. Same cores. Just placed."

[Don't narrate over it. Let them see it. This is the slide they'll remember in the hallway.]
-->

---
layout: section
---

# 6. Zero-Downtime Deploys

<div class="text-xl opacity-70 mt-4">
  Cordon. Drain. The same primitives.
</div>

<!--
[Say:]
"Section six — zero-downtime deploys. The payoff. Same primitives we've been using, doing the real production work."

[Pause. Advance.]

[Budget: ~6 min through end of §6.]
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
[Say:]
"Two operations are enough to drive a clean shutdown — cordon and drain."

[click]
"Cordon: remove a node from the ring everywhere. Workers on the cordoned node see 'I'm not the owner anymore' on their next rebalance tick. Built on Ring plus :erpc — no new mechanism."

[click]
"Drain: wait for the local worker count to hit zero. No central tracking; just poll WorkerSupervisor."

[click]
"And here's how this lands in production. kubectl rollout restart sends SIGTERM to each pod in turn. The BEAM catches it, runs GracefulShutdown.terminate/2, cordons, drains, then exits. The replacement pod is a NEW node — it joins on startup, :nodeup fires everywhere, ring picks it up. No orchestrator code."

[Speak the kubectl sequence slowly: SIGTERM → terminate/2 → cordon → drain → exit → new pod → :nodeup → ring updates. Each arrow is a primitive we've already learned. Advance.]

[On the uncordon question if asked: in production a restarted pod is a brand new BEAM node with a new name. :nodeup handles re-adding. Uncordon only matters when the same node comes back, which doesn't happen on real deploys.]
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
[Walk through the code:]
"Last child in the supervision tree. init traps exits. terminate cordons this node, kicks rebalance, then drains until empty."

[click]
"Being the last child means terminate/2 runs BEFORE the rest of the app stops — that's how we get to drain cleanly before shutdown."

[click]
"trap_exit is a PROCESS-lifecycle hook; monitor_nodes was a CLUSTER-lifecycle one. Different events, same idea: the runtime tells you when something changes — you subscribe and react."

[Then say aloud (not on slide):]
"kubectl rollout restart looks identical to clicking the dashboard button."

[Don't claim this is "the monitor_nodes shape again" — it's not. trap_exit is a different primitive. The honest framing is the broader pattern: the BEAM hands you lifecycle events; you subscribe and react.]
-->

---
clicks: 1
---

# Rolling deploy timeline

<RollingDeployTimeline :clicks="$clicks" class="mt-2" />

<!--
[Walk the audience through the predicted shape BEFORE the live demo — they'll know what to watch for.]

[Say:]
"Four lanes — one per node. Each lane goes active, cordoned, draining, restarting, then back to active. Watch the line at the bottom: that's total active workers across the whole cluster."

[click]
"Lanes change color — work is moving. But the total worker count never moves. That's the whole talk in one image."

[Pause. Let the flat line land. If you want to replay, navigate away and back.]
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
[Pre-flight: 4-node cluster, workers spread evenly, dashboard open with Rolling Deploy button visible, callbacks counter visible.]

[Say:]
"The audience just saw the predicted timeline. Now the real dashboard."

[Demo (~2 min):]

1. Click Rolling Deploy. Talk over the ~20s rotation:
   - "Watch B's worker count hit zero — that's the drain."
   - "Watch A, C, and D absorb evenly — that's the ring."
   - "Watch the callbacks counter — that's the SLO."

2. In one iex: Ctrl-C, a to hard-kill node D.
   ":nodedown recovery in about five seconds. Survivors pick up D's work."

3. Restart D.
   ":nodeup, workers redistribute back."

[Two demos in one: graceful rotation, then violent failure. Both look identical from the dashboard's perspective. The callbacks counter's uninterrupted climb is the whole point.]

[Failure mode: if Rolling Deploy hangs, skip to the hard-kill — it's the more memorable half.]
-->

---
layout: section
---

# 7. Caveats

<!--
[Say:]
"Section seven — caveats. Quick. Where this approach doesn't fit."

[Pause. Advance.]

[Budget: ~2 min through end of §7.]
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
[Say:]
"Five caveats, briefly. Where placement-by-hash doesn't fit."

[click]
"Workers pinned to a node — local file, GPU, attached disk. Breaks the model."

[click]
"Expensive warm-up state. If workers are stateful between events, you need to checkpoint or accept a re-warm on migration."

[click]
"Flap windows. If a node bounces nodedown to nodeup in under a second, a worker can move twice."

[click]
"Cluster size at a thousand-plus nodes. Every node holding the full ring stops being free — shard the ring or use a different model."

[click]
"Diverged membership views. libring assumes every node sees the same membership; get your libcluster config right."

[Don't dwell. The room knows you're being honest. Advance.]
-->

---
layout: section
---

# 8. Wrap

<!--
[Say:]
"Section eight — wrap. Three things to leave the room with, then we land the opening question."

[Pause. Advance.]

[Budget: ~2 min through end of §8, then Q&A.]
-->

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
[Say:]
"Three things to leave the room with."

[click]
"About 200 lines of application code. The runtime gave us cluster membership, monitoring, and :erpc for free."

[click]
"One primitive, two consumers. A GenServer that calls monitor_nodes and reacts to :nodeup / :nodedown. libring uses it internally. Placement uses it in your code. Same primitive, same job."

[click]
"No library between you and the runtime. When something goes wrong at 3am, the whole stack is in your codebase."

[The middle bullet is the pedagogical takeaway — if they remember nothing else, they remember the GenServer shape.]
-->

---
clicks: 1
---

# Two answers

<ClosingImage :clicks="$clicks" class="mt-2" />

<!--
[Same image they saw 40 minutes ago. Pause for recognition.]

[Say:]
"Forty minutes ago I asked: which node runs the GenServer for X, and how does any other node send it a message?"

[Pause.]

[click]
"Ring.owner answers the first question. :erpc answers the second. That's the whole talk."

[Let "the whole talk" land. Then advance to Thanks for Q&A.]
-->

---
layout: center
class: text-center
---

# Thanks

<div class="mt-8 text-xl opacity-80 space-y-2">

<div>github.com/JohnnyT/heartbeats</div>

</div>

<div class="mt-12 text-2xl text-amber-400 font-semibold">

Questions?

</div>

<!--
[The closing line landed on the previous slide (Two Answers). This slide is utilitarian — repo, slides, and an explicit Q&A invitation.]

[Stay here for the whole Q&A. The audience can read the URL while you talk.]
-->
