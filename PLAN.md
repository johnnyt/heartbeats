# `heartbeats` — Implementation Plan

A Phoenix demo that visualizes how `libring` distributes long-running heartbeat
processes evenly across an Elixir cluster, and how the cluster self-heals when
nodes come and go.

## Decisions locked in

- **Naming**: split the sibling project's `HeartbeatScheduler` into a pure
  `Heartbeats.Ring` module + a `Heartbeats.Placement` GenServer. Worker, Registry,
  and supervisor names drop the redundant `Heartbeat*` prefix.
- **Storage**: shared **Postgres** via Ecto, single source of truth for every
  node. Phases 1–6 used a replicated ETS store with PubSub-driven sync; Phase
  6.5 swaps to Postgres so the storage layer fades into the background and
  libring + `:erpc` stand out as the interesting parts. Aligns with the
  production sibling. (Earlier rejected alternatives: ETS-only forced us to
  hand-roll replication that paralleled the libring story rather than
  reinforcing it; a single-owner GenServer would be a SPOF that breaks the
  Chaos demo; worker-as-state would lose subs on `kill -9`.)
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
| Subscription Ecto schema | `Heartbeats.Subscription` |
| Subscriptions context (Repo wrapper) | `Heartbeats.Subscriptions` |
| Ecto repo | `Heartbeats.Repo` |
| Public facade | `Heartbeats` |
| Phoenix endpoint | `HeartbeatsWeb.Endpoint` |
| Register/delete API | `HeartbeatsWeb.SubscriptionController` |
| Mock callback receiver | `HeartbeatsWeb.CallbackController` |
| Live dashboard | `HeartbeatsWeb.ClusterLive` |
| Cluster supervisor | `Heartbeats.ClusterSupervisor` |
| PubSub | `Heartbeats.PubSub` |
| SIGTERM / shutdown drain | `Heartbeats.GracefulShutdown` |

## Final supervision tree

1. `Heartbeats.Repo` — Ecto Postgres repo (every node connects to the same DB)
2. `Heartbeats.PubSub` — `Phoenix.PubSub` adapter (used for live deploy/chaos events; storage no longer needs it)
3. `{Cluster.Supervisor, [topology, [name: Heartbeats.ClusterSupervisor]]}` — *conditional* on `should_cluster?/2`
4. `{Registry, keys: :unique, name: Heartbeats.Registry}`
5. `Heartbeats.WorkerSupervisor` — DynamicSupervisor
6. `Heartbeats.Placement` — RPC target; monitors `:net_kernel.monitor_nodes/1`; on `:nodeup`/`:nodedown` broadcasts `:rebalance` to its local workers
7. `Heartbeats.RollingDeploy` — GenServer driving cordon/drain/uncordon sequences
8. `HeartbeatsWeb.Endpoint` — child starts on every node, but only binds an HTTP listener when the BEAM was started via `mix phx.server`. Headless cluster members (`iex -S mix`) skip the listener naturally.
9. `Heartbeats.GracefulShutdown` — last child; supervisors stop in reverse order, so its `terminate/2` runs first on shutdown and drains the node

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

- [x] `iex --name a@127.0.0.1 -S mix phx.server` boots cleanly; `localhost:4100` shows the Phoenix welcome page.
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

- [x] `mix quality` passes.
- [x] A test asserts that `Heartbeats.register/1` results in a `Worker` registered under `Heartbeats.Registry`.
- [x] A test asserts that broadcasting a `{:put, sub}` to `"subscriptions"` results in the receiver node's ETS containing the row.

### Manual verification

In three terminals, all three nodes should converge on the same picture.

```sh
# T1 — runs the dashboard
iex --name a@127.0.0.1 -S mix phx.server
# T2 / T3 — headless cluster members (no `phx.server`, no HTTP listener)
iex --name b@127.0.0.1 -S mix
iex --name c@127.0.0.1 -S mix
```

- [x] On `a`, `Node.list()` returns `[:b@127.0.0.1, :c@127.0.0.1]`.
- [x] On `a`, register 30 subscriptions pointing at `http://localhost:4100/callbacks/<id>`:
  ```elixir
  for i <- 1..30, do: Heartbeats.register(%{callback_url: "http://localhost:4100/callbacks/sub#{i}", interval_ms: 5_000})
  ```
- [x] On every node, `Heartbeats.Subscriptions.count()` returns `30` (replication works).
- [x] On every node, `Registry.count(Heartbeats.Registry)` is roughly `10` (±a few — consistent hashing, not perfectly even). Sum across nodes = 30.
- [x] On `a`, look up a worker pid for a known subscription; kill it with `Process.exit(pid, :kill)`. Within seconds it restarts (DynamicSupervisor `:transient`) on the same node.
- [x] No HTTP 500s in the Phoenix log (callbacks may 404 since `CallbackController` doesn't exist yet — that's fine; the worker should log and continue).

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

- [x] `mix quality` passes.
- [x] Multi-node ExUnit test: 3-node cluster, 30 subs, kill one node — within 5s the orphans are running on the surviving two.
- [x] Multi-node ExUnit test: 2-node cluster, register 30 subs, start a 3rd node — within 5s ~1/3 of the workers have migrated to the new node.
- [x] Multi-node ExUnit test: graceful `Application.stop(:heartbeats)` on one node — the node's local worker count drops to 0 before the application fully stops; survivors absorb the workers; no missed heartbeats.

### Manual verification

- [x] Three nodes running; 30 subscriptions registered (~10 each).
- [x] **Sudden death**: `kill -9 <pid>` on node `c`'s BEAM. Within ~5s, `a` and `b`'s `Registry.count(Heartbeats.Registry)` collectively return 30. The previously-on-`c` subscriptions are now distributed across `a` and `b`.
- [x] **Graceful shutdown**: in node `c`'s iex, run `:init.stop()` (or `Ctrl-C, a`). Watch the log show `Heartbeats.GracefulShutdown` cordoning, rebalancing, and waiting for drain. `c`'s local worker count hits 0 before the BEAM exits. No errors logged on `a` or `b` from missed heartbeats.
- [x] Restart node `c`. Within ~5s, ~10 workers have migrated back to `c`.
- [x] No worker is registered on more than one node simultaneously (would be a critical bug — verify by collecting `{node, worker_id}` tuples across all three nodes and asserting uniqueness).
- [x] Log output on every node shows `[:heartbeats, :placement, :rebalanced]` events on each topology change.

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

- [x] `mix quality` passes.
- [x] `mix test` passes. Controller tests cover happy path + 4xx for malformed input.
- [x] End-to-end test: `POST /api/subscriptions` with `interval_ms: 500` → wait 1.5s → `GET /api/subscriptions` shows it → callback counter for that id ≥ 2.

### Manual verification

- [x] `curl -XPOST localhost:4100/api/subscriptions -H 'content-type: application/json' -d '{"callback_url":"http://localhost:4100/api/callbacks/demo1","interval_ms":2000}'` returns 201 with an `owner_node`.
- [x] `curl localhost:4100/api/subscriptions` lists it.
- [x] In the Phoenix log on the owner node, observe a heartbeat POST every ~1.8s (90% of 2000).
- [x] In the Phoenix log on the receiver node (whichever has port 4100), observe `CallbackController.receive` being hit.
- [x] `curl -XDELETE localhost:4100/api/subscriptions/demo1` returns 204; heartbeats stop.
- [x] Register a subscription on node `a` whose ring owner is node `c`. Confirm `c`'s log shows the heartbeat POSTs (the worker is on `c`) while the callback lands on `a`'s `CallbackController` (the only node serving HTTP).

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

- [x] `mix quality` passes.
- [x] `mix test` — at least one `Phoenix.LiveViewTest` that mounts `ClusterLive`, registers a subscription via the public API, and asserts it appears in the rendered HTML.

### Manual verification

- [x] Open `localhost:4100` in one browser tab. (Only node `a` runs the dashboard; `b` and `c` are headless cluster members and don't serve HTTP.)
- [x] All three show 3 nodes, 0 subscriptions.
- [x] Click "Spawn 100 subscriptions" on any tab. All three tabs update within ~1s to show ~33 workers per node.
- [x] Heartbeat counters climb visibly.
- [x] Kill node `c` (`Ctrl-C, a` in its terminal). Within ~5s, the other two tabs show `c` as `:down`, its workers redistributed.
- [x] Restart `c`. Tabs show it returning, workers migrating back.

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

- [x] `mix quality` passes.
- [x] `mix test` — ExUnit test for `Chaos.random_kill/0` on a 2-node test cluster: assert workers transiently disappear and come back.
- [x] `mix test` — ExUnit test for `RollingDeploy.start/0` on a 3-node test cluster: assert each node is cordoned exactly once, drained, then uncordoned, in sequence; total workers preserved throughout (modulo the brief restart window).

### Manual verification

- [x] Run the 3-node setup; spawn 100 subs; click **Inject Chaos**. One node's workers flicker; counts return to ~33 within seconds. No subscriptions lost.
- [x] Click **Rolling Deploy**. Watch each node in turn: its worker count drops to 0 (workers migrate to the other two), holds for the configured pause, then returns to ~33 as the next node starts draining. Dashboard pill cycles through `:cordoned` → `:draining` → `:live`.
- [x] Total worker count across all live nodes stays at 100 throughout the rolling deploy (no dropped subscriptions).
- [x] Heartbeats received counter on the dashboard keeps climbing throughout — no perceptible gap, demonstrating zero-downtime.
- [x] Click **Rolling Deploy** twice quickly: second click is a no-op (or shows a flash like "already in progress").

🛑 **PAUSE — wait for confirmation that manual verification passed before starting Phase 6.5.**

---

## Phase 6.5 — Swap replicated ETS for shared Postgres

**Goal**: Move the source of truth for subscriptions and callback counts into
a shared Postgres database. Every node connects to the same DB; the
hand-rolled replication layer goes away. Dashboard reads everything off the
DB on its 1-second tick — the live counter and the per-node subtotals stay in
lockstep because they're derived from the same query.

**Why now**: The replicated-ETS pattern was teaching alongside libring rather
than reinforcing it. With a familiar Ecto-backed store, the libring + `:erpc`
mechanics become the obvious main characters. Aligns with the production
sibling (which is Postgres-backed), which is a nice "this is how it really
works" handoff.

**Postgres, not SQLite**: SQLite serializes writes, has cross-process file-lock
quirks, and isn't what production looks like. Postgres is one `brew install
postgresql@16 && brew services start postgresql@16` (or equivalent) and then
identical to prod.

### Files / actions

- **Deps**: add `{:ecto_sql, "~> 3.12"}`, `{:postgrex, ">= 0.0.0"}`,
  `{:phoenix_ecto, "~> 4.6"}`. Keep `:phoenix_live_dashboard` (already there).

- **`lib/heartbeats/repo.ex`** — new. `use Ecto.Repo, otp_app: :heartbeats,
  adapter: Ecto.Adapters.Postgres`.

- **`lib/heartbeats/subscription.ex`** — convert from struct to Ecto schema:
  ```elixir
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "subscriptions" do
    field :callback_url, :string
    field :interval_ms, :integer
    field :verifier, :string
    field :callbacks_count, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end
  ```
  - `new/1` → `changeset/1` returning `%Ecto.Changeset{}`.
  - `generate_id/0` stays (used by `register_many`).

- **`lib/heartbeats/subscriptions.ex`** — collapse the GenServer into a thin
  context module:
  - `put/1` → `Repo.insert(changeset, on_conflict: :replace_all,
    conflict_target: :id)` + broadcast `{:put, sub}` for the dashboard's
    instant refresh.
  - `delete/1` → `Repo.delete_all(from s in Subscription, where: s.id == ^id)`
    + broadcast `{:delete, id}`.
  - `get/1` → `Repo.get(Subscription, id)`.
  - `all/0` → `Repo.all(Subscription)`.
  - `count/0` → `Repo.aggregate(Subscription, :count, :id)`.
  - `purge_local/0` → keep its current job (terminate every locally-running
    worker), drop the ETS clear (DB-backed now). `Heartbeats.clear_all/0`
    keeps `:erpc.multicall` to every node for `purge_local`, plus a single
    `Repo.delete_all(Subscription)`.

- **`lib/heartbeats/callback_stats.ex`** — **delete**. The counter becomes
  the `callbacks_count` column. Replaced by:
  - In `HeartbeatsWeb.CallbackController.receive_heartbeat/2`:
    `Repo.update_all(from(s in Subscription, where: s.id == ^id), inc:
    [callbacks_count: 1])`. No PubSub broadcast — dashboard polls.

- **`lib/heartbeats/application.ex`** — drop `Heartbeats.CallbackStats` and
  the legacy `Heartbeats.Subscriptions` GenServer; add `Heartbeats.Repo` as
  the first child.

- **`lib/heartbeats_web/live/cluster_live.ex`** — three changes:
  1. **Drop the `{:callback_received}` handler**. The header counter now
     refreshes on the 1-second `:tick` along with everything else, so it
     stays in lockstep with per-node subtotals (no more "header at 318,
     bottom adds to 312" drift).
  2. Drop the `:chaos` topic subscription's `:stats_replica` machinery
     (gone with `CallbackStats`). The chaos banner still works via
     `{:chaos, :killed, …}` / `{:chaos, :recovered, …}`.
  3. `refresh_state/1` does one `Repo.all(Subscription)` and reads
     `callbacks_count` directly off each row. No more `CallbackStats.all()`
     map merge.

- **`priv/repo/migrations/<timestamp>_create_subscriptions.exs`** — single
  migration creating the `subscriptions` table. Index on `id` (PK is enough),
  no other indexes needed for demo scale.

- **`config/config.exs`** — add `config :heartbeats, ecto_repos:
  [Heartbeats.Repo]`.

- **`config/dev.exs`** — repo config (username/password from env, default
  `postgres`/`postgres`, database `heartbeats_dev`).

- **`config/test.exs`** — repo config (database `heartbeats_test`,
  `pool: Ecto.Adapters.SQL.Sandbox`).

- **`config/runtime.exs`** — read `DATABASE_URL` for prod-style runs;
  default to local for dev.

- **`mix.exs`** aliases — add `setup` to run `ecto.create` + `ecto.migrate` +
  `assets.setup` so `mix setup` works for first-time clones.

- **`test/support/data_case.ex`** — new, standard Phoenix Ecto sandbox case.
  Tests that hit the DB `use Heartbeats.DataCase` for sandbox isolation.

- **`test/support/heartbeats_case.ex`** + **`test/support/cluster_case.ex`** —
  switch to sandbox-aware setup. For `ClusterCase` peers also need
  `Ecto.Adapters.SQL.Sandbox.allow/3` to share the test connection across
  RPC boundaries (or each peer uses `Sandbox.mode/2` in its setup).

- **`test/heartbeats/callback_stats_test.exs`** — delete.

- **`test/heartbeats_test.exs`**, **`test/heartbeats/subscriptions_test.exs`**,
  controller tests — adjust assertions for Ecto records (`%Subscription{}`
  with timestamps, etc.) and DB-backed counts.

- **`test/heartbeats/cluster_test.exs`** — the "callback stats replicate
  across the cluster" test gets reframed: every peer sees the same
  `callbacks_count` because they share the DB, not because of replication.
  Same assertion, different mechanism.

### Automatic verification

- [x] `mix quality` passes.
- [x] `mix ecto.create && mix ecto.migrate` runs cleanly.
- [x] All previous tests pass against the new storage (subscription_controller,
      callback_controller, cluster_test, etc.).
- [x] `Heartbeats.CallbackStats` is gone; no stragglers (`grep -r CallbackStats lib/`
      returns nothing).
- [x] No more `"callbacks_replica"` PubSub topic.

### Manual verification

Three terminals as before — but first `mix ecto.create && mix ecto.migrate`
once.

```sh
iex --name a@127.0.0.1 -S mix phx.server     # dashboard + HTTP
iex --name b@127.0.0.1 -S mix                # headless cluster member
iex --name c@127.0.0.1 -S mix                # headless cluster member
```

- [x] All three nodes connect to the same DB; spawning subs from any node
      shows up in the single dashboard tab within ~1s.
- [x] The header `N callbacks received` and the sum of per-node `callbacks`
      always match (in lockstep at every 1-second refresh).
- [x] **Sudden death** of node `c@`: surviving nodes adopt orphans within
      ~5s. The DB still has the subs (no replication needed).
- [x] **Inject Chaos**: chosen node's worker count drops, banner shows for
      ~2.5s, then bounces back. Same as before.
- [x] **Rolling Deploy**: each phase visible, total worker count preserved,
      dashboard counters smooth.
- [x] **Clear All**: every node's worker count + DB row count both drop to 0.

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
- **Cross-peer Ecto sandbox** in `ClusterCase` — peer nodes started by `:peer` will need to share the test runner's DB connection (via `Ecto.Adapters.SQL.Sandbox.allow/3`) or run in `:shared` sandbox mode. Decide during Phase 6.5 once the regular sandbox is wired.
