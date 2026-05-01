# `heartbeats` — Implementation Plan

A Phoenix demo that visualizes how `libring` distributes long-running heartbeat
processes evenly across an Elixir cluster, and how the cluster self-heals when
nodes come and go.

## Decisions locked in

- **Naming**: split the sibling project's `HeartbeatScheduler` into a pure
  `Heartbeats.Ring` module + a `Heartbeats.Placement` GenServer. Worker, Registry,
  and supervisor names drop the redundant `Heartbeat*` prefix.
- **Storage**: ETS only. No Postgres, no `Bootstrap` task. Each subscription
  registration is broadcast (via `Phoenix.PubSub`) to every node so every node
  has the full set in its local ETS — required for ownership transfer when a
  node dies. (Why not mnesia? It would dominate the codebase mentally and
  compete with libring for the reader's attention. Why not a single owner
  GenServer? Single point of failure that breaks the Chaos demo. Why not
  worker-as-state? A `kill -9` on a node loses subscriptions with no peer copy.)
- **Graceful shutdown**: SIGTERM / `Ctrl-C` triggers a `GracefulShutdown`
  GenServer that cordons the local node, calls `rebalance_local/0`, and waits
  for workers to drain before the BEAM exits. Mirrors what a real k8s rolling
  restart does, and what the Rolling Deploy button simulates.
- **Multi-node tests**: use OTP's built-in `:peer` (since OTP 25). Avoid
  `LocalCluster` — its older versions wrap the deprecated `:slave` module;
  `:peer` is stdlib and long-term-stable.
- **Tooling**: `ex_quality` configures Credo / Dialyxir / coverage / etc. Run its
  installer immediately after the dep is fetched.
- **Demo controls**: dashboard has a **Chaos** button (kill a random node's
  workers) and a **Rolling Deploy** button (cordon → drain → uncordon, one node
  at a time).

## Naming reference

| Concern | Module |
|---|---|
| Pure libring wrapper | `Heartbeats.Ring` |
| Per-node placement GenServer (RPC target) | `Heartbeats.Placement` |
| DynamicSupervisor for workers | `Heartbeats.WorkerSupervisor` |
| Per-subscription GenServer | `Heartbeats.Worker` |
| Registry of running workers | `Heartbeats.Registry` (atom name) |
| Subscription struct | `Heartbeats.Subscription` |
| Replicated in-memory store | `Heartbeats.Subscriptions` |
| Public facade | `Heartbeats` |
| Phoenix endpoint | `HeartbeatsWeb.Endpoint` |
| Register/delete API | `HeartbeatsWeb.SubscriptionController` |
| Mock callback receiver | `HeartbeatsWeb.CallbackController` |
| Live dashboard | `HeartbeatsWeb.ClusterLive` |
| Cluster supervisor | `Heartbeats.ClusterSupervisor` |
| PubSub | `Heartbeats.PubSub` |
| SIGTERM / shutdown drain | `Heartbeats.GracefulShutdown` |

## Final supervision tree

1. `Heartbeats.PubSub` — `Phoenix.PubSub` adapter
2. `{Cluster.Supervisor, [topology, [name: Heartbeats.ClusterSupervisor]]}` — *conditional* on `should_cluster?/2`
3. `{Registry, keys: :unique, name: Heartbeats.Registry}`
4. `Heartbeats.Subscriptions` — ETS owner GenServer, subscribes to `"subscriptions"` PubSub topic for replication
5. `Heartbeats.WorkerSupervisor` — DynamicSupervisor
6. `Heartbeats.Placement` — RPC target; monitors `:net_kernel.monitor_nodes/1`; on `:nodeup`/`:nodedown` broadcasts `:rebalance` to its local workers
7. `HeartbeatsWeb.Endpoint`
8. `Heartbeats.GracefulShutdown` — last child; supervisors stop in reverse order, so its `terminate/2` runs first on shutdown and drains the node

---

## Phase 1 — Skeleton, deps, tooling

**Goal**: Fresh Phoenix app boots; `ex_quality` is installed and its tools are
configured; `libcluster` + `libring` + `req` are pulled in but not yet wired.

### Files / actions

- `mix phx.new heartbeats --no-ecto --module Heartbeats --app heartbeats` (run from `/Users/johnnyt/repos/github/`).
- Add deps to `mix.exs`:
  ```elixir
  {:ex_quality, "~> X.Y", only: [:dev, :test], runtime: false},
  {:libcluster, "~> 3.5"},
  {:libring, "~> 1.7"},
  {:req, "~> 0.5"}
  ```
- `mix deps.get`.
- Run `mix quality.init` — `ex_quality`'s installer. **It is interactive; answer the prompts** (Credo, Dialyzer, coverage thresholds, etc.). Commit its generated config files.
- `config/config.exs`: add the libring ring config:
  ```elixir
  config :libring,
    rings: [heartbeats: [monitor_nodes: true, node_type: :visible]]
  ```
- `config/runtime.exs`: add `clustering_enabled` toggle (default `true`, overridable by env).
- `lib/heartbeats/application.ex`: add the `should_cluster?/2` helper — port the `:nonode@nohost` escape hatch verbatim. Add `Cluster.Supervisor` to children when enabled. Use `Cluster.Strategy.LocalEpmd` topology.
- Strip generated boilerplate that we won't use (no Ecto, no mailer, no heroicons demo page if Phoenix scaffolds one).

### Automatic verification

- [x] `mix deps.get` succeeds with no warnings about missing version constraints.
- [x] `mix quality` passes (umbrella: compile/format/credo/dialyzer/test/coverage).

### Manual verification

- [x] `iex --name a@127.0.0.1 -S mix phx.server` boots cleanly; `localhost:5000` shows the Phoenix welcome page.
- [x] `iex --name a@127.0.0.1 -S mix` followed by `Node.list()` returns `[]` without crashing (LocalEpmd strategy active, no peers yet).
- [x] Without `--name`: `iex -S mix` does **not** start the cluster supervisor (verify by checking `:supervisor.which_children(Heartbeats.Supervisor)` — no `Cluster.Supervisor` child).
- [x] `Heartbeats.Ring` not yet present (we'll add it next phase) — confirm by `Code.ensure_loaded?(Heartbeats.Ring)` returning `false`.

🛑 **PAUSE — wait for confirmation that manual verification passed before starting Phase 2.**

---

## Phase 2 — Ring, Placement, Worker, replicated Subscriptions

**Goal**: Register a subscription via `iex` on any node; a `Heartbeats.Worker` for
it starts on the ring-owner node; killing the worker process restarts it on the
correct node automatically.

### Files / actions

- `lib/heartbeats/subscription.ex` — bare struct: `id`, `callback_url`, `interval_ms`, `verifier`. Plus a `new/1` constructor that fills `verifier` with `:crypto.strong_rand_bytes(16) |> Base.url_encode64()`.

- `lib/heartbeats/subscriptions.ex` — GenServer + ETS table (named, `:public`, `:set`). API:
  - `put(%Subscription{})` — inserts locally **and** broadcasts `{:put, sub}` to `"subscriptions"` PubSub.
  - `delete(id)` — same, broadcasts `{:delete, id}`.
  - `get(id)` / `all/0` / `count/0` — ETS reads.
  - On init, subscribes to `"subscriptions"` topic; `handle_info({:put, _}, _)` writes locally without re-broadcasting.

- `lib/heartbeats/ring.ex` — pure module:
  ```elixir
  def owner(id),     do: HashRing.Managed.key_to_node(:heartbeats, id)
  def members,       do: HashRing.Managed.nodes(:heartbeats)
  def cordon(node),  do: # :erpc.multicall to remove_node on every member
  def uncordon(node),do: # :erpc.multicall to add_node on every member
  ```

- `lib/heartbeats/worker_supervisor.ex` — `DynamicSupervisor`. `start_worker(sub)` builds the child spec with `restart: :transient`.

- `lib/heartbeats/worker.ex` — GenServer:
  - Registered under `{:via, Registry, {Heartbeats.Registry, {:worker, sub.id}}}`.
  - `init/1` stores `%{subscription: sub}` and `send(self(), :send_heartbeat)` for the immediate first beat.
  - `handle_info(:send_heartbeat, state)` POSTs `%{kind: "subscription", action: "check", id:, verifier:}` with `subscription-protocol: callback/1.0` header, then schedules next via `Process.send_after(self(), :send_heartbeat, interval - grace)`.
  - `handle_info(:rebalance, state)` recomputes `Ring.owner/1`. If `== Node.self()`, no-op. Else: ask the new owner to start it, then `{:stop, {:shutdown, :rebalanced}, state}`.
  - Emits `[:heartbeats, :worker, :sent | :failed | :placed | :rebalanced]` telemetry events.

- `lib/heartbeats/placement.ex` — GenServer:
  - `place(sub)` — public API. If `Ring.owner(sub.id) == Node.self()`, calls `WorkerSupervisor.start_worker(sub)` locally. Else `GenServer.call({Heartbeats.Placement, owner}, {:place, sub})`.
  - `unplace(id)` — symmetric for stop.
  - `rebalance_local/0` — sends `:rebalance` to every locally-supervised worker.
  - (Auto-rebalance on `:nodeup`/`:nodedown` lands in Phase 3.)

- `lib/heartbeats.ex` — facade:
  ```elixir
  def register(attrs),  do: # build sub, Subscriptions.put, Placement.place
  def unregister(id),   do: # Placement.unplace, Subscriptions.delete
  def list,             do: Subscriptions.all()
  def cordon(node \\ Node.self()), do: Ring.cordon(node)
  def uncordon(node \\ Node.self()), do: Ring.uncordon(node)
  ```

- Tests: unit tests for `Ring` (use a single local node), `Subscriptions` (broadcast/replication assertions with `Phoenix.PubSub` test helpers), and a `Worker` test that uses `Bypass` or a stub callback URL to assert the POST shape.

### Automatic verification

- [ ] `mix quality` passes.
- [ ] A test asserts that `Heartbeats.register/1` results in a `Worker` registered under `Heartbeats.Registry`.
- [ ] A test asserts that broadcasting a `{:put, sub}` to `"subscriptions"` results in the receiver node's ETS containing the row.

### Manual verification

In three terminals, all three nodes should converge on the same picture.

```sh
# T1
iex --name a@127.0.0.1 -S mix phx.server
# T2
PORT=5001 iex --name b@127.0.0.1 -S mix phx.server
# T3
PORT=5002 iex --name c@127.0.0.1 -S mix phx.server
```

- [ ] On `a`, `Node.list()` returns `[:b@127.0.0.1, :c@127.0.0.1]`.
- [ ] On `a`, register 30 subscriptions pointing at `http://localhost:5000/callbacks/<id>`:
  ```elixir
  for i <- 1..30, do: Heartbeats.register(%{callback_url: "http://localhost:5000/callbacks/sub#{i}", interval_ms: 5_000})
  ```
- [ ] On every node, `Heartbeats.Subscriptions.count()` returns `30` (replication works).
- [ ] On every node, `Registry.count(Heartbeats.Registry)` is roughly `10` (±a few — consistent hashing, not perfectly even). Sum across nodes = 30.
- [ ] On `a`, look up a worker pid for a known subscription; kill it with `Process.exit(pid, :kill)`. Within seconds it restarts (DynamicSupervisor `:transient`) on the same node.
- [ ] No HTTP 500s in the Phoenix log (callbacks may 404 since `CallbackController` doesn't exist yet — that's fine; the worker should log and continue).

🛑 **PAUSE — wait for confirmation that manual verification passed before starting Phase 3.**

---

## Phase 3 — Auto-rebalance + graceful shutdown

**Goal**: When a node joins or leaves the cluster, every node automatically
recomputes ownership for its local workers and migrates the ones that no longer
belong to it. Additionally, SIGTERM / `Ctrl-C` triggers a graceful drain on the
exiting node so no heartbeats are dropped during a clean shutdown.

### Files / actions

- `lib/heartbeats/placement.ex`:
  - `init/1`: `:net_kernel.monitor_nodes(true, node_type: :visible)`.
  - `handle_info({:nodeup, _, _}, state)` and `handle_info({:nodedown, _, _}, state)`: call `rebalance_local/0` (with a small `Process.send_after` debounce, ~250ms, so multiple nearly-simultaneous events coalesce).
  - When a `:nodedown` happens, the surviving nodes' `Subscriptions` ETS still has every subscription. Each surviving `Placement` iterates the ETS, and for any subscription whose `Ring.owner/1` is now `Node.self()` and which has no worker registered locally, `place/1` it.
  - Emit `[:heartbeats, :placement, :rebalanced]` with metrics: how many migrated in, how many migrated out.

- `lib/heartbeats/graceful_shutdown.ex` — new GenServer, added as the **last** child in the application supervision tree (so `terminate/2` runs first when the supervisor stops in reverse order):
  - `init/1`: `Process.flag(:trap_exit, true)`.
  - `terminate/2`:
    1. `Ring.cordon(Node.self())` — RPCs every other node to `HashRing.Managed.remove_node/2` so they stop routing new work here.
    2. `Placement.rebalance_local()` — every local worker recomputes its owner, RPCs the new owner, then stops.
    3. Poll the local `Registry` count until it reaches 0 or a 5s deadline elapses.
    4. Return `:ok`.
  - The default `mix release` SIGTERM handling triggers `Application.stop/1`, which stops the top-level supervisor, which runs this child's `terminate/2`. In `iex --name a@127.0.0.1 -S mix`, `Ctrl-C, a` triggers the same path.

- `test/support/cluster_case.ex` — new helper using OTP's built-in `:peer`. Boilerplate: start N peer nodes, set their code paths to the test project, `Application.ensure_all_started(:heartbeats)` on each, connect them. Tear down in `on_exit`. ExUnit tags `:cluster` and `async: false` for these.

- Multi-node ExUnit tests under `test/heartbeats/cluster/`:
  - `rebalance_test.exs`: 3-node cluster, 30 subs, kill one node, assert orphans land on the survivors.
  - `node_join_test.exs`: 2-node cluster with 30 subs, start a 3rd node, assert ~1/3 migrate.
  - `graceful_shutdown_test.exs`: 3-node cluster, ask one node to `Application.stop(:heartbeats)`, assert that during the shutdown window heartbeat throughput on the other two stays within ~10% of pre-shutdown levels (no dropped beats during drain).

### Automatic verification

- [ ] `mix quality` passes.
- [ ] Multi-node ExUnit test: 3-node cluster, 30 subs, kill one node — within 5s the orphans are running on the surviving two.
- [ ] Multi-node ExUnit test: 2-node cluster, register 30 subs, start a 3rd node — within 5s ~1/3 of the workers have migrated to the new node.
- [ ] Multi-node ExUnit test: graceful `Application.stop(:heartbeats)` on one node — the node's local worker count drops to 0 before the application fully stops; survivors absorb the workers; no missed heartbeats.

### Manual verification

- [ ] Three nodes running; 30 subscriptions registered (~10 each).
- [ ] **Sudden death**: `kill -9 <pid>` on node `c`'s BEAM. Within ~5s, `a` and `b`'s `Registry.count(Heartbeats.Registry)` collectively return 30. The previously-on-`c` subscriptions are now distributed across `a` and `b`.
- [ ] **Graceful shutdown**: in node `c`'s iex, run `:init.stop()` (or `Ctrl-C, a`). Watch the log show `Heartbeats.GracefulShutdown` cordoning, rebalancing, and waiting for drain. `c`'s local worker count hits 0 before the BEAM exits. No errors logged on `a` or `b` from missed heartbeats.
- [ ] Restart node `c`. Within ~5s, ~10 workers have migrated back to `c`.
- [ ] No worker is registered on more than one node simultaneously (would be a critical bug — verify by collecting `{node, worker_id}` tuples across all three nodes and asserting uniqueness).
- [ ] Log output on every node shows `[:heartbeats, :placement, :rebalanced]` events on each topology change.

🛑 **PAUSE — wait for confirmation that manual verification passed before starting Phase 4.**

---

## Phase 4 — HTTP surface

**Goal**: External clients can register / delete subscriptions via JSON HTTP.
The same app exposes a callback receiver so heartbeats land somewhere and we
can count them.

### Files / actions

- `lib/heartbeats_web/router.ex`:
  ```
  scope "/api", HeartbeatsWeb do
    pipe_through :api
    post "/subscriptions",      SubscriptionController, :create
    delete "/subscriptions/:id", SubscriptionController, :delete
    get "/subscriptions",        SubscriptionController, :index
    post "/callbacks/:id",       CallbackController,    :receive
  end
  ```

- `lib/heartbeats_web/controllers/subscription_controller.ex`:
  - `create/2`: build subscription, `Heartbeats.register/1`, return 201 with `{id, callback_url, owner_node}`.
  - `delete/2`: `Heartbeats.unregister/1`, 204.
  - `index/2`: `Heartbeats.list/0`, JSON list with `owner_node` derived from `Ring.owner/1`.

- `lib/heartbeats_web/controllers/callback_controller.ex`:
  - `receive/2`: validate `subscription-protocol: callback/1.0` header. Increment a per-id counter (ETS table named `:heartbeats_received`, public, set, write_concurrency). Broadcast `{:received, id, node_received_on}` to `"callbacks"` PubSub for the dashboard.
  - Returns 204.

- `lib/heartbeats_web/plugs/json_required.ex` — small plug to require `application/json` on the API pipeline.

- Controller tests with `Phoenix.ConnTest`. End-to-end test: register → wait one interval → assert callback counter incremented.

### Automatic verification

- [ ] `mix quality` passes.
- [ ] `mix test` passes. Controller tests cover happy path + 4xx for malformed input.
- [ ] End-to-end test: `POST /api/subscriptions` with `interval_ms: 500` → wait 1.5s → `GET /api/subscriptions` shows it → callback counter for that id ≥ 2.

### Manual verification

- [ ] `curl -XPOST localhost:5000/api/subscriptions -H 'content-type: application/json' -d '{"callback_url":"http://localhost:5000/api/callbacks/demo1","interval_ms":2000}'` returns 201 with an `owner_node`.
- [ ] `curl localhost:5000/api/subscriptions` lists it.
- [ ] In the Phoenix log on the owner node, observe a heartbeat POST every ~1.8s (90% of 2000).
- [ ] In the Phoenix log on the receiver node (whichever has port 5000), observe `CallbackController.receive` being hit.
- [ ] `curl -XDELETE localhost:5000/api/subscriptions/demo1` returns 204; heartbeats stop.
- [ ] Register a subscription on node `a` (port 5000), but its ring owner is node `c` (port 5002). Confirm `c`'s log shows the heartbeat POSTs while `a`'s log doesn't.

🛑 **PAUSE — wait for confirmation that manual verification passed before starting Phase 5.**

---

## Phase 5 — LiveView dashboard

**Goal**: A page at `/` shows live cluster state and heartbeat activity. This
is the part that sells the demo.

### Files / actions

- `lib/heartbeats/telemetry_pubsub.ex` — small handler that attaches to
  `[:heartbeats, :worker, :sent]`, `[:heartbeats, :placement, :rebalanced]`, and
  republishes to `Phoenix.PubSub` topics `"dashboard:nodes"` and
  `"dashboard:beats"`.

- `lib/heartbeats_web/live/cluster_live.ex`:
  - Mount: subscribe to PubSub topics; collect initial state (members from `Ring.members/0`, per-node worker counts via `:erpc.multicall(Heartbeats.Placement, :stats, [])`).
  - State: `%{nodes: [%{name, worker_count, beats_last_30s, status: :live | :cordoned | :down}], subscriptions: [%{id, owner_node, beats_received}]}`.
  - Rendered as a table per node, plus a list/grid of subscriptions colored by their owning node.
  - Polling tick every 1s for counters; PubSub events for instant updates on placement changes.

- `lib/heartbeats/placement.ex`: add `stats/0` returning `%{worker_count: n, cordoned?: bool}`.

- A "Spawn 100 subscriptions" button on the dashboard for fast demoing. POSTs to the API in a loop server-side (don't actually create 100 LiveView events).

- Make the dashboard the root route; move Phoenix's default landing page to `/welcome` or delete it.

### Automatic verification

- [ ] `mix quality` passes.
- [ ] `mix test` — at least one `Phoenix.LiveViewTest` that mounts `ClusterLive`, registers a subscription via the public API, and asserts it appears in the rendered HTML.

### Manual verification

- [ ] Open `localhost:5000`, `:5001`, `:5002` in three browser tabs.
- [ ] All three show 3 nodes, 0 subscriptions.
- [ ] Click "Spawn 100 subscriptions" on any tab. All three tabs update within ~1s to show ~33 workers per node.
- [ ] Heartbeat counters climb visibly.
- [ ] Kill node `c` (`Ctrl-C, a` in its terminal). Within ~5s, the other two tabs show `c` as `:down`, its workers redistributed.
- [ ] Restart `c`. Tabs show it returning, workers migrating back.

🛑 **PAUSE — wait for confirmation that manual verification passed before starting Phase 6.**

---

## Phase 6 — Chaos & Rolling Deploy buttons

**Goal**: Two prominent buttons on the dashboard let a presenter demonstrate the
self-healing behavior without touching a terminal.

### Files / actions

- `lib/heartbeats/chaos.ex`:
  - `random_kill/0`: pick a random node from `Ring.members/0`, RPC `:erpc.cast(node, Heartbeats.Chaos, :kill_local_workers, [])`. Locally: list children of `WorkerSupervisor`, `Process.exit(pid, :kill)` for each. They restart (transient) but it spikes the dashboard satisfyingly.
  - Optionally a "scorched earth" mode: cordon the node, kill all its workers, the rebalance migrates them off; uncordon after 5s.

- `lib/heartbeats/rolling_deploy.ex`:
  - `start/0`: spawns a Task that, for each node in `Ring.members/0`, in series:
    1. `Ring.cordon(node)` — broadcasts removal from the ring.
    2. Wait until the cordoned node's local worker count drops to 0 (poll `Placement.stats/0` via RPC, ≤10s).
    3. Optional pause (~2s, configurable) to make the rolling motion visible.
    4. `Ring.uncordon(node)` — adds it back.
    5. Wait for rebalance to settle (worker counts within 20% of fair share, ≤10s).
    6. Move to the next node.
  - Emits `[:heartbeats, :rolling_deploy, :step]` telemetry events for the dashboard.
  - Guarded against concurrent runs (a registered name; second invocation is a no-op + flash).

- Dashboard:
  - Two buttons: "Inject Chaos" and "Rolling Deploy". Latter is disabled while a
    rolling deploy is in flight; shows a progress strip ("Cordoning b@…",
    "Draining b@…", "Uncordoning b@…", "Done").
  - Per-node row gains a status pill: `:live` / `:cordoned` / `:draining` / `:down`.

### Automatic verification

- [ ] `mix quality` passes.
- [ ] `mix test` — ExUnit test for `Chaos.random_kill/0` on a 2-node test cluster: assert workers transiently disappear and come back.
- [ ] `mix test` — ExUnit test for `RollingDeploy.start/0` on a 3-node test cluster: assert each node is cordoned exactly once, drained, then uncordoned, in sequence; total workers preserved throughout (modulo the brief restart window).

### Manual verification

- [ ] Run the 3-node setup; spawn 100 subs; click **Inject Chaos**. One node's workers flicker; counts return to ~33 within seconds. No subscriptions lost.
- [ ] Click **Rolling Deploy**. Watch each node in turn: its worker count drops to 0 (workers migrate to the other two), holds for the configured pause, then returns to ~33 as the next node starts draining. Dashboard pill cycles through `:cordoned` → `:draining` → `:live`.
- [ ] Total worker count across all live nodes stays at 100 throughout the rolling deploy (no dropped subscriptions).
- [ ] Heartbeats received counter on the dashboard keeps climbing throughout — no perceptible gap, demonstrating zero-downtime.
- [ ] Click **Rolling Deploy** twice quickly: second click is a no-op (or shows a flash like "already in progress").

🛑 **PAUSE — wait for confirmation that manual verification passed before starting Phase 7.**

---

## Phase 7 — README & polish

**Goal**: A reader can clone, run three nodes, and reproduce the demo from the
README in under five minutes.

### Files / actions

- `README.md`:
  - 30-second pitch + a screenshot/GIF of the dashboard during a rolling deploy.
  - Local-dev quickstart (the three-terminal recipe).
  - Architecture section linking to each module's role.
  - Walkthrough: register subs → chaos button → rolling deploy. Three short paragraphs each.
  - "How libring fits in" — the 5-line explanation of consistent hashing + `monitor_nodes: true`.
  - Pointers to the production sibling (with a note that this is a teaching POC: ETS only, no persistence, no auth).

- Tighten any rough edges surfaced during the previous phases. Examples:
  - Sensible defaults for `interval_ms` (e.g., reject `< 500` to avoid an accidental DoS on the local box).
  - Cap "Spawn N" at a sane number.
  - Friendly empty states on the dashboard (no workers / no nodes / cluster not enabled).

- Confirm `mix quality` passes end-to-end with the configured coverage threshold met.

### Automatic verification

- [ ] All previous auto-verify checkboxes still pass.
- [ ] `mix quality` passes.
- [ ] Coverage threshold from `ex_quality` config is met.

### Manual verification

- [ ] Fresh clone of the repo; follow the README's quickstart from scratch on a clean machine. Demo works end-to-end without consulting any other doc.
- [ ] Screenshots / GIF in the README accurately reflect current UI.

🛑 **PAUSE — final review.**

---

## Open questions to resolve as we go

- **Subscription verifier authentication on the callback receiver** — strictly speaking, Apollo HTTP Callback Protocol checks the verifier matches. For the demo we can accept all callbacks (since the same app sends and receives), but a single check would be a nice educational touch.
