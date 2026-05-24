---
theme: seriph
title: Spreading Long-Running Workloads Across an Elixir Cluster
info: |
  A story about consistent hashing, :erpc, and zero-downtime deploys.
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
  A story about consistent hashing, <code>:erpc</code>, and zero-downtime deploys.
</div>

<div class="abs-bl mx-14 my-12 flex gap-2 opacity-60">
  <span>JohnnyT</span>
  <span>·</span>
  <span>github.com/JohnnyT/heartbeats</span>
</div>

<!--
Opening slide — name and repo on screen before they sit down.<br>
Audience: Elixir folks, already bought in. We're not justifying the runtime.<br>
We're comparing libring + :erpc to other *Elixir* answers (:global, Horde, Swarm).
-->

---
layout: section
---

# 1. The Problem

<!--
5 minutes. Anchor in a concrete workload before any solutions.
-->

---

# N long-running GenServers that each need a home

<v-clicks>

- Absinthe **subscription heartbeats**
- Phoenix **Channel sockets**
- Per-tenant **pollers**
- **Log tailers**
- "One worker per X" anything

</v-clicks>

<!--
Quick survey: "who's reached for Horde? For :global? For Swarm? For a
homegrown registry on :pg?" 90 seconds max — calibrates the room and seeds §2.
-->

---

# What makes placement hard

<v-clicks>

<div class="mt-8 space-y-6">

<div>
  <div class="text-2xl font-semibold text-indigo-400">Stateful</div>
  <div class="text-lg opacity-80">Round-robin at the LB doesn't help. The <em>process</em> is the state.</div>
</div>

<div>
  <div class="text-2xl font-semibold text-teal-400">Long-lived</div>
  <div class="text-lg opacity-80">Placement decisions stick for hours or days — not the milliseconds a task takes.</div>
</div>

<div>
  <div class="text-2xl font-semibold text-amber-400">Membership churn is the steady state</div>
  <div class="text-lg opacity-80">Nodes leave (deploys, autoscaling, crashes) and join (scale-up, restarts) constantly. The placement layer has to redistribute on every event without dropping work.</div>
</div>

</div>

</v-clicks>

<!--
The third bullet is doing real work — it's the lens for both the scale-up/down demo (§5) and the rolling deploy demo (§6).<br>
When they see both demos behave the same way, they'll recognize it as the same property: membership churn → ring redistribution.
-->

---

# Two questions every BEAM-native solution must answer

<div class="grid grid-cols-2 gap-8 mt-12">

<div class="text-2xl">

**1.** Which node runs the GenServer for key `X`?

</div>

<div class="text-2xl">

**2.** How does any other node send it a message?

</div>

</div>

<div v-click class="mt-16 text-center text-3xl">

Both reduce to one: <span class="font-bold text-amber-400">placement</span>.

</div>

<div v-click class="mt-4 text-center text-xl opacity-80">

Once you can answer "who owns <code>X</code>," <code>:erpc</code> handles the rest.

</div>

<!--
This is the thesis of the whole talk in two questions. Land "placement" hard —
the rest of the deck is justifying that decomposition.
-->

---
clicks: 1
---

# Both questions reduce to one

<PlacementQuestion :clicks="$clicks" class="mt-4" />

<!--
Animation: on the first click, the two pulsing question marks dissolve and a single "?" lands centered above the cluster — labelled "placement."<br>
This is the visual punchline for "both questions reduce to one."<br>
Stay on this slide while you say "the rest of the talk is justifying that decomposition," then click into §2.
-->

---
layout: section
---

# 2. How We'd Solve This in Elixir Today

<div class="text-xl opacity-70 mt-4">
  <code>:global</code>, Swarm, Horde — and why we're going to decompose them.
</div>

<!--
6 minutes. The audience is already wondering "why not Horde?" — answer that head-on.<br>
Two stops: :global (the naïve answer) and Horde (the real answer).
-->

---

# `:global` — the obvious first answer

```elixir
:global.register_name({:worker, sub_id}, self())
:global.whereis_name({:worker, sub_id})
#=> #PID<12345.678.0> or :undefined
```

<v-clicks>

<div class="mt-8 text-lg opacity-90">

The runtime already tracks cluster membership. <em>Just let it track names too.</em>

</div>

</v-clicks>

<!--
Set up the trap. This is what every Elixir dev reaches for first when they
need cross-node naming. Show the code, let the room nod along, then turn the
page and break it.
-->

---

# Where `:global` falls down for placement

<div class="mt-6 space-y-6">

<div v-click>
  <div class="text-xl font-semibold text-rose-400">No placement policy</div>
  <div class="text-base opacity-80">Whichever node calls <code>register_name/2</code> first owns it. Add a node and existing names <em>don't redistribute</em> — there's no "~1/N moves" property; there's no movement at all.</div>
</div>

<div v-click>
  <div class="text-xl font-semibold text-rose-400">Cluster-wide locking on register</div>
  <div class="text-base opacity-80">Every registration is a full mesh round-trip. Fine at 10 names. Painful at 10k.</div>
</div>

<div v-click>
  <div class="text-xl font-semibold text-rose-400">Netsplit conflict resolution kills processes</div>
  <div class="text-base opacity-80">When two partitions heal and both registered the same name, <code>:global</code>'s default resolver <em>exits one of them</em>. Most teams meet this property in production.</div>
</div>

</div>

<!--
Land the third bullet hard — "name uniqueness, by murder." That phrase is
the diagram caption too. Audience laughs; you've earned the next 30 minutes.
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
*click* "Heal the partition. :global notices the conflict and… exits one of them."
-->

---
layout: center
---

# Swarm tried to fix this

<div class="text-xl opacity-80 mt-6 max-w-3xl mx-auto leading-relaxed">

Handoff + an internal hash ring. Largely unmaintained now — but the <em>idea</em> was right.

</div>

<div v-click class="mt-8 text-2xl text-amber-400 font-semibold">

We're going to build directly on the ring.

</div>

<!--
One slide for Swarm. Name it so the room knows you know the history.<br>
The ring is the idea Swarm got right; the rest of the talk is doing that idea cleanly without the dead-framework baggage.
-->

---
layout: section
---

# Horde — distributed registry + supervisor

<!--
Don't dodge it. The audience is mentally running "why not just Horde?" for the whole talk if you don't address it now.<br>
Keep the section divider clean — no subtitle the audience has to parse.
-->

---

# Horde

```elixir
Horde.DynamicSupervisor.start_child(MySup, {Worker, sub})
Horde.Registry.lookup(MyRegistry, sub.id)
```

<div class="mt-8 text-lg opacity-90">

Explicitly built for "distributed supervisor that rebalances on membership change."

</div>

<!--
Show respect. Horde is a real, well-built library.<br>
This is the mental model the audience is already running — don't dodge it.<br>
Address Horde fully on its own terms. We're not comparing to anything yet.
-->

---

# What Horde gives you

<div class="mt-8 space-y-5">

<div v-click class="flex gap-4 items-start">
  <div class="text-emerald-400 text-2xl">✓</div>
  <div class="text-xl">Auto-rebalance on <code>:nodeup</code> / <code>:nodedown</code></div>
</div>

<div v-click class="flex gap-4 items-start">
  <div class="text-emerald-400 text-2xl">✓</div>
  <div class="text-xl">Cluster-wide name registry with handoff</div>
</div>

<div v-click class="flex gap-4 items-start">
  <div class="text-emerald-400 text-2xl">✓</div>
  <div class="text-xl">Process state hand-off hooks on migration</div>
</div>

</div>

<!--
This list matters. Don't rush past the checkmarks.<br>
Horde is a real, well-built library doing real work — establish that before we look at the design choices behind it.
-->

---

# How does Horde know who owns what?

<div class="mt-8 space-y-5 max-w-4xl">

<div v-click>
  <div class="text-xl font-semibold">Each node holds its own copy of the registry</div>
  <div class="text-base opacity-75 mt-1">Local read, no round-trip.</div>
</div>

<div v-click>
  <div class="text-xl font-semibold">Updates gossip between nodes via delta-CRDTs</div>
  <div class="text-base opacity-75 mt-1">Powered by the <code>DeltaCrdt</code> library. Each node sends only what changed.</div>
</div>

<div v-click>
  <div class="text-xl font-semibold">All copies converge — eventually</div>
  <div class="text-base opacity-75 mt-1">Milliseconds in a healthy cluster. Longer under load or partition.</div>
</div>

</div>

<div v-click class="mt-10 text-xl text-amber-400 font-semibold max-w-3xl">

"Eventually" is not zero.

</div>

<!--
This is the slide that makes the convergence-window discussion legible.<br>
Land the three mechanics first — local copy, gossip, converge.<br>
Then drop "eventually is not zero" hard. That's the seed for the next slide.<br>
If anyone's never seen a CRDT, this is enough — they don't need the math.
-->

---

# So what happens during convergence?

<div class="mt-6 space-y-5 max-w-4xl">

<div v-click>
  <div class="text-lg font-semibold text-amber-400">Two nodes can disagree about ownership</div>
  <div class="text-sm opacity-80 leading-relaxed">Before gossip lands, node A thinks it owns <code>sub-42</code>; node C also thinks it owns <code>sub-42</code>. Both start workers.</div>
</div>

<div v-click>
  <div class="text-lg font-semibold text-amber-400">Two workers run for the same key</div>
  <div class="text-sm opacity-80 leading-relaxed">For the duration of the convergence window — often milliseconds, occasionally longer.</div>
</div>

<div v-click>
  <div class="text-lg font-semibold text-amber-400">Horde resolves once gossip converges</div>
  <div class="text-sm opacity-80 leading-relaxed">The CRDT picks a winner, the other worker gets terminated. The Horde README is explicit about this. Teams in production hit it.</div>
</div>

</div>

<!--
This is the heavyweight slide of the section — give it a beat.<br>
The audience should leave knowing exactly what "the convergence window" means and what it costs.<br>
Don't editorialize — just describe what happens. Whether it's tolerable depends on the workload, and that's the next slide.
-->

---
layout: center
---

# Is the convergence window the right tradeoff?

<div v-click class="mt-10 text-xl opacity-85 max-w-3xl mx-auto leading-relaxed">

For workloads that need <strong>cluster-wide uniqueness guarantees</strong> — clearly yes. Horde is the right tool.

</div>

<div v-click class="mt-6 text-xl opacity-85 max-w-3xl mx-auto leading-relaxed">

For workloads where a brief duplicate during a netsplit is <em>unacceptable</em> — we can ask the runtime for less, and do more locally.

</div>

<div v-click class="mt-10 text-2xl text-amber-400 font-semibold">

That's the rest of the talk.

</div>

<!--
This is the honest close to the Horde section.<br>
The first click validates Horde for the workloads it's built for.<br>
The second click sets up the next 35 minutes without naming the alternative yet.<br>
"Ask the runtime for less, do more locally" is the thesis of §3-§6 in one phrase.
-->

---
layout: section
---

# 3. The Elixir Primitives

<div class="text-xl opacity-70 mt-4">
  Two superpowers. We'll compose them.
</div>

<!--
8 minutes. First live demo is in this section.<br>
Two primitives: (1) the cluster as a queryable thing, (2) :erpc.<br>
Then the pivot: naïve placement fails, motivating the ring.
-->

---

# The cluster is a thing you can ask questions of

```elixir
Node.self()        #=> :"a@127.0.0.1"
Node.list()        #=> [:"b@127.0.0.1", :"c@127.0.0.1"]
```

<v-click>

<div class="mt-8 text-lg opacity-90 max-w-3xl">

<code>Node.list()</code> is <em>not</em> a service-discovery API call. The runtime maintains the membership; you're reading a <strong>local data structure</strong>.

</div>

</v-click>

<v-click>

<div class="mt-6 text-xl text-amber-400 font-semibold">

This is the difference that makes everything else possible.

</div>

</v-click>

<!--
For the BEAM-curious in the room: emphasize the "local data structure" line.<br>
Most people coming from other ecosystems hear "cluster membership" and picture Consul/etcd/ZK round-trips. The BEAM runtime maintains a synchronously-updated local view.<br>
This is what makes libring possible — every node can compute placement locally with no coordination.
-->

---

# And the runtime tells you when membership changes

```elixir
:net_kernel.monitor_nodes(true)

# inbox now receives:
#   {:nodeup,   :"b@127.0.0.1"}
#   {:nodedown, :"b@127.0.0.1"}
```

<v-click>

<div class="mt-8 text-lg opacity-90 max-w-3xl">

Any <code>GenServer</code> can subscribe. <em>This</em> is the foundation for automatic rebalance.

</div>

</v-click>

<v-click>

<div class="mt-6 text-base opacity-70 max-w-3xl">

We'll see it again later — in our placement code, and powering the ring under the hood.

</div>

</v-click>

<!--
This slide is doing setup for §4 and §5 simultaneously.<br>
Don't dwell — the audience will see it cash out twice in the next 15 minutes.<br>
Just land "any GenServer can subscribe" — that's the seed.
-->

---

# Discovery: one config block, no code

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

No discovery code in your app. <code>libcluster</code> handles it.

</div>

</v-click>

<!--
libcluster is the discovery layer underneath everything.<br>
Mention K8s-style deployment briefly — the audience will recognize it.<br>
Point: this is shrink-wrapped. You won't think about discovery again in this talk.
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

<!--
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

# 📊 Diagram 4 — `:erpc` in one frame

<div class="flex items-center justify-center h-96 border border-dashed border-gray-600 rounded-lg mt-4">
  <div class="text-center opacity-60 leading-relaxed">
    <div class="text-xl">[ Placeholder for animated diagram ]</div>
    <div class="mt-3 text-sm">
      Two BEAM lozenges side by side, <code>a@</code> and <code>b@</code>.<br/>
      Step 1: arrow from <code>a@</code> → <code>b@</code> labeled <code>:erpc.call(b, Mod, :fun, [arg])</code><br/>
      Step 2: <code>b@</code> runs the function (small spinner)<br/>
      Step 3: return-value arrow back to <code>a@</code><br/>
      Caption morph: <em class="text-amber-400">"no service discovery · no auth handshake · no JSON · no HTTP — just call a function."</em>
    </div>
  </div>
</div>

<!--
Diagram 4 spec lives in docs/talk-outline.md §3b.<br>
TODO: build as components/ErpcInOneFrame.vue — simplest diagram so far. Click reveals each step.<br>
The caption is the punchline — it should land on the final click.
-->

---

# Naïve placement

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

Which means we just rebuilt the same coordination problem we were trying to avoid.

</div>

</v-click>

<!--
This is the pivot moment. Show the naïve code, let the room think "yeah okay so just use this," then break it on the second click.<br>
Don't rush through "we just rebuilt the coordinator" — that's the connection back to §2's tradeoffs.
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
layout: center
class: text-center
---

# Rest of the deck: TODO

§4 libring · §5 Placement · §6 Deploys · §7 Caveats · §8 Wrap

<div class="mt-8 opacity-60">
  See <code>docs/talk-outline.md</code> for the full outline.
</div>
