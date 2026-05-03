# Heartbeats

A Phoenix demo that visualizes how [`libring`](https://hex.pm/packages/libring)
distributes long-running processes evenly across an Elixir cluster, and how
the cluster self-heals when nodes come and go.

The workload — sending heartbeats to active GraphQL subscriptions per the
[Apollo HTTP Callback Protocol](https://www.apollographql.com/docs/graphos/routing/operations/subscriptions/callback-protocol)
— is just a hook. The interesting parts are the consistent-hash placement,
the cross-node `:erpc` routing, and the cordon/drain orchestration.

## What it shows

- **Even spread**: register 50 subscriptions and watch libring's consistent
  hash deal them out roughly evenly across nodes.
- **Self-healing**: kill a node and the surviving nodes adopt its workers
  within a couple of seconds — no shared queue, no dispatcher, just a hash
  ring + RPC.
- **Rolling deploy**: cordon → drain → uncordon, one node at a time, with
  zero dropped subscriptions during the rotation.
- **Chaos**: brutally terminate every worker on a random node, watch the
  cluster recover.

## Stack

| Layer | Choice | Why |
|---|---|---|
| Language | Elixir 1.19 / OTP 28 | pinned via `mise.toml` |
| Web | Phoenix 1.8 + LiveView 1.1 | the dashboard is a single LiveView |
| Storage | Postgres via Ecto | shared across all nodes — the subscriptions table is the source of truth |
| Clustering | `libcluster` (`Cluster.Strategy.LocalEpmd`) | auto-discovers `iex --name` peers on the same host |
| Placement | `libring` (consistent hash, `monitor_nodes: true`) | maps `subscription_id → node` and updates ring on `:nodeup`/`:nodedown` automatically |
| RPC | OTP `:erpc` | `:erpc.multicall` for stats fan-out, `:erpc.cast` for fire-and-forget rebalance triggers |
| Tests | OTP `:peer` | spawns multi-node test clusters; the modern replacement for `:slave` |
| Quality | `ex_quality` | runs format/credo/dialyzer/test/coverage in parallel |

## Quickstart

You'll need:

- [mise](https://mise.jdx.dev/) — installs the pinned Elixir/Erlang versions.
- Postgres reachable on `localhost:5432`. One of:
  - **Docker** (recommended): `docker compose up -d`
  - **Homebrew**: `brew install postgresql@16 && brew services start postgresql@16`
- Three terminals.

```sh
# Once:
mise install                # Elixir 1.19.4-otp-28 + Erlang 28.3.1
mix setup                   # deps + ecto.create + ecto.migrate + assets

# Three terminals. Only node `a` runs the dashboard; `b` and `c` are
# headless cluster members (they don't run `phx.server`, so the endpoint
# starts but binds no HTTP port).
iex --name a@127.0.0.1 -S mix phx.server
iex --name b@127.0.0.1 -S mix
iex --name c@127.0.0.1 -S mix
```

Open one browser tab at <http://localhost:4100>. The dashboard sees the
whole cluster: it queries every node via `:erpc.multicall` for worker
counts and reads subscriptions + callback counts from the shared
Postgres. You don't need a dashboard per node — that would just show the
same picture three times.

## Demo walkthrough

### 1. Spread the load

Click **Spawn** with the defaults (10 subscriptions at 5s interval). Each
tab updates within ~1s:

- The **Nodes** table shows ~3 workers per node.
- The **Subscriptions by node** cards group each subscription under its
  ring-determined owner.
- The **callbacks received** counter starts climbing.

Bigger demo: spawn 100 at 2s. Or via `iex`:

```elixir
Heartbeats.register_many(100, %{interval_ms: 2_000})
```

### 2. Inject Chaos

Click **Inject Chaos**. A random node is picked; every worker on it is
terminated. A red banner appears for ~2.5s while the cluster recovers, then
the worker count rebounds to its previous value as `Placement.rebalance_local`
re-adopts the orphaned subscriptions on the same node.

This demonstrates: workers are processes, processes can die, but the
subscriptions don't go with them — they're rows in Postgres, and the
placement layer notices the gap.

### 3. Rolling Deploy

Click **Rolling Deploy**. One node at a time:

1. **Cordon** — remove from every node's ring.
2. **Drain** — workers detect they're no longer the owner and migrate
   themselves to a new owner via `:erpc`.
3. **Uncordon** — re-add to the ring; trigger a rebalance so workers
   migrate back.
4. Pause briefly. Move to the next node.

Total worker count across surviving nodes stays constant. The "callbacks
received" counter keeps climbing — no perceptible gap.

This is what a real Kubernetes rolling restart looks like, just compressed
into ~15 seconds.

### 4. Hard kill

In one of the iex sessions: `Ctrl-C, a` (or kill the BEAM externally).
Surviving nodes detect `:nodedown`, libring removes the dead node from the
ring, and `Placement` adopts the orphaned subscriptions within ~5s.

For a graceful version: `:init.stop()` in iex. The `GracefulShutdown`
module's `terminate/2` fires *first* (it's the last child in the
supervision tree), cordons the node, calls `rebalance_local/0`, and waits
for workers to migrate off before the BEAM exits.

### 5. Clear

Click **Clear all subscriptions**. Every node's worker count drops to 0,
every Subscriptions row is deleted, every callback counter resets.

## How libring fits in

The whole "which node runs the worker for subscription X?" decision is one
function call:

```elixir
HashRing.Managed.key_to_node(:heartbeats, subscription_id)
```

The ring itself is configured globally (`config/config.exs`):

```elixir
config :libring,
  rings: [heartbeats: [monitor_nodes: true, node_type: :visible]]
```

`monitor_nodes: true` is the magic — libring hooks
`:net_kernel.monitor_nodes/1` and updates the ring automatically when peers
join or leave. We never call `add_node`/`remove_node` ourselves outside of
the cordon/uncordon paths.

That's it. Everything else (placement, rebalance, chaos recovery, rolling
deploy) is built on top of these two primitives.

## Architecture

```
HTTP request                                  Heartbeats firing
     │                                              ▲
     ▼                                              │
HeartbeatsWeb.SubscriptionController               Worker (per sub)
     │                                              │
     ▼                                              ▼
Heartbeats.register/1                       Req.post(callback_url)
     │                                              │
     │  Repo.insert    ┌────────────────────────────┘
     │                 │
     ▼                 ▼
Subscriptions    HeartbeatsWeb.CallbackController
   (Postgres)         │
                      ▼
              Repo.update_all(... inc: [callbacks_count: 1])
```

Per-subscription worker placement:

```
Heartbeats.register/1
  → Subscriptions.put/1     (Repo.insert + PubSub broadcast for live UI)
  → Placement.place/1       (consults Ring, RPCs the owner)
  → WorkerSupervisor.start_worker/1  (DynamicSupervisor on the owner node)
  → Worker GenServer        (HTTP heartbeats every ~interval_ms × 0.9)
```

| Module | Role |
|---|---|
| [`Heartbeats.Ring`](lib/heartbeats/ring.ex) | Pure libring wrapper: `owner/1`, `members/0`, `cordon/1`, `uncordon/1` |
| [`Heartbeats.Placement`](lib/heartbeats/placement.ex) | Per-node GenServer + RPC target. Decides where workers run; subscribes to `:net_kernel.monitor_nodes/1` for auto-rebalance |
| [`Heartbeats.WorkerSupervisor`](lib/heartbeats/worker_supervisor.ex) | DynamicSupervisor — one per node, owns the local heartbeat workers |
| [`Heartbeats.Worker`](lib/heartbeats/worker.ex) | Per-subscription GenServer. Sends HTTP heartbeats; on `:rebalance` self-migrates if the ring owner changed |
| [`Heartbeats.Subscription`](lib/heartbeats/subscription.ex) | Ecto schema — `id` (UXID), `callback_url`, `interval_ms`, `verifier`, `callbacks_count` |
| [`Heartbeats.Subscriptions`](lib/heartbeats/subscriptions.ex) | Repo wrapper — `put/get/all/count/delete/purge_local` |
| [`Heartbeats.Chaos`](lib/heartbeats/chaos.ex) | `random_kill/0` picks a random ring member and terminates its workers; visible recovery delay |
| [`Heartbeats.RollingDeploy`](lib/heartbeats/rolling_deploy.ex) | GenServer driving cordon → drain → uncordon for each node in turn |
| [`Heartbeats.GracefulShutdown`](lib/heartbeats/graceful_shutdown.ex) | Last child in the supervision tree; SIGTERM-triggered drain |
| [`HeartbeatsWeb.ClusterLive`](lib/heartbeats_web/live/cluster_live.ex) | Real-time dashboard at `/` |

## HTTP API

```
GET    /api/subscriptions             → list every subscription with ring owner_node
POST   /api/subscriptions             → register one (returns 201 + serialized sub)
DELETE /api/subscriptions/:id         → unregister + stop worker
POST   /api/callbacks/:id             → callback receiver (Worker → here)
```

Quick sanity check via `curl`:

```sh
curl -XPOST localhost:4100/api/subscriptions \
  -H 'content-type: application/json' \
  -d '{"callback_url":"http://localhost:4100/api/callbacks/demo","interval_ms":2000}'

curl localhost:4100/api/subscriptions
```

## Tests

```sh
mix test                  # unit + controller + LiveView tests, ~3s
mix test --include cluster   # also the multi-node :peer tests, ~45s
mix quality               # full umbrella: format, credo, dialyzer, tests, coverage
```

Multi-node tests use OTP's `:peer` (Phoenix tests use the standard sandbox;
cluster tests switch the Repo to `:auto` mode in `setup_all` since peers
on different BEAM nodes can't share a sandbox checkout).

## Scope of this demo

This is a **teaching POC**. It deliberately doesn't ship with:

- Auth / authorization
- Verifier validation on the callback receiver
- Rate limiting, retries, backoff on the heartbeat HTTP path
- A persistent subscription source (the local Phoenix endpoint plays both
  registrant and callback receiver)

For a production-shaped version of the same pattern with Postgres CDC,
gRPC, observability, and Apollo Router integration, see the sibling
`graphql-subscriptions` project at Bill.

## License

MIT.
