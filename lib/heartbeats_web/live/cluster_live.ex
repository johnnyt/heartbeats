defmodule HeartbeatsWeb.ClusterLive do
  @moduledoc """
  Real-time view of the cluster:

    * a row per node (worker count, status, callbacks for owned subs)
    * one card per node grouping the subscriptions it currently owns —
      makes the libring distribution visually obvious
    * a "spawn N subscriptions" form
    * a "clear all" button

  Per-subscription owner and callback count are precomputed and grouped by
  owner node so the diff engine can see them as concrete assign values
  (function calls inside templates aren't tracked by the diff compiler).

  Subscribes to:
    * `"subscriptions"` — register/delete events trigger a refresh so the
      table updates immediately on user action (the 1s tick would catch up
      anyway).
    * `"deploy"` and `"chaos"` — banner state for the demo controls.

  Polls every second on a `:tick`. Subscription rows + callback counts come
  from a single `Heartbeats.list/0` query (Postgres is shared, so any node
  sees the same rows). Cross-node worker counts come from a parallel
  `:erpc.multicall` to each node's `Placement.stats/0`.
  """

  use HeartbeatsWeb, :live_view

  alias Heartbeats.{Chaos, Placement, Ring, RollingDeploy}

  @refresh_ms 1_000
  @rpc_timeout_ms 500
  @max_spawn 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Heartbeats.PubSub, "subscriptions")
      Phoenix.PubSub.subscribe(Heartbeats.PubSub, "deploy")
      Phoenix.PubSub.subscribe(Heartbeats.PubSub, "chaos")
      Process.send_after(self(), :tick, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:max_spawn, @max_spawn)
     |> assign(:deploy_state, :idle)
     |> assign(:chaos_state, :idle)
     |> refresh_state()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, refresh_state(socket)}
  end

  def handle_info({:put, _sub}, socket), do: {:noreply, refresh_state(socket)}
  def handle_info({:delete, _id}, socket), do: {:noreply, refresh_state(socket)}

  ## Rolling deploy lifecycle

  def handle_info({:deploy, {:start, total}}, socket) do
    {:noreply,
     assign(socket, :deploy_state, %{
       phase: :starting,
       current: nil,
       message: "Starting rolling deploy across #{total} nodes…"
     })}
  end

  def handle_info({:deploy, {:cordon, node}}, socket) do
    {:noreply,
     assign(socket, :deploy_state, %{
       phase: :cordoning,
       current: node,
       message: "Cordoning #{node}…"
     })}
  end

  def handle_info({:deploy, {:draining, node, remaining}}, socket) do
    {:noreply,
     assign(socket, :deploy_state, %{
       phase: :draining,
       current: node,
       message: "Draining #{node} (#{remaining} workers remaining)…"
     })}
  end

  def handle_info({:deploy, {:uncordon, node}}, socket) do
    {:noreply,
     assign(socket, :deploy_state, %{
       phase: :uncordoning,
       current: node,
       message: "Uncordoning #{node}…"
     })}
  end

  def handle_info({:deploy, :complete}, socket) do
    {:noreply,
     socket
     |> assign(:deploy_state, :idle)
     |> put_flash(:info, "Rolling deploy complete")
     |> refresh_state()}
  end

  def handle_info({:deploy, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:deploy_state, :idle)
     |> put_flash(:error, "Rolling deploy failed: #{inspect(reason)}")}
  end

  ## Chaos events

  def handle_info({:chaos, :killed, node, count}, socket) do
    {:noreply, assign(socket, :chaos_state, %{node: node, count: count})}
  end

  def handle_info({:chaos, :recovered, node}, socket) do
    case socket.assigns.chaos_state do
      %{node: ^node} -> {:noreply, assign(socket, :chaos_state, :idle)}
      _other -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("spawn", %{"count" => count_str, "interval_seconds" => seconds_str}, socket) do
    with {count, ""} when count > 0 <- Integer.parse(count_str || ""),
         {seconds, ""} when seconds >= 1 <- Integer.parse(seconds_str || "") do
      count = min(count, @max_spawn)
      Heartbeats.register_many(count, %{interval_ms: seconds * 1_000})

      {:noreply,
       socket
       |> put_flash(:info, "Registered #{count} subscriptions at #{seconds}s interval")
       |> refresh_state()}
    else
      _other ->
        {:noreply, put_flash(socket, :error, "count must be ≥ 1 and interval ≥ 1 second")}
    end
  end

  def handle_event("clear_all", _params, socket) do
    Heartbeats.clear_all()

    {:noreply,
     socket
     |> put_flash(:info, "Cleared all subscriptions across the cluster")
     |> refresh_state()}
  end

  def handle_event("inject_chaos", _params, socket) do
    case Chaos.random_kill() do
      {:ok, %{node: node, killed: killed}} ->
        {:noreply, put_flash(socket, :info, "Killed #{killed} workers on #{node}")}

      {:error, :no_nodes} ->
        {:noreply, put_flash(socket, :error, "No nodes in the ring to chaos")}
    end
  end

  def handle_event("rolling_deploy", _params, socket) do
    case RollingDeploy.begin() do
      :ok ->
        {:noreply, put_flash(socket, :info, "Rolling deploy started")}

      {:error, :already_running} ->
        {:noreply, put_flash(socket, :error, "Rolling deploy already in progress")}

      {:error, :no_nodes} ->
        {:noreply, put_flash(socket, :error, "No nodes in the ring to deploy")}
    end
  end

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-6 space-y-6">
      <header class="flex items-center justify-between">
        <h1 class="text-3xl font-bold">Heartbeats Cluster</h1>
        <div class="text-sm text-base-content/70">
          {@total_subscriptions} subscriptions · <span class="font-mono">{@total_callbacks}</span>
          callbacks received
        </div>
      </header>

      <%= if @deploy_state != :idle do %>
        <div class="alert alert-info">
          <span class="loading loading-spinner loading-sm"></span>
          <span>{@deploy_state.message}</span>
        </div>
      <% end %>

      <%= if @chaos_state != :idle do %>
        <div class="alert alert-error">
          <span class="loading loading-spinner loading-sm"></span>
          <span>
            Chaos on <span class="font-mono">{@chaos_state.node}</span>: killed {@chaos_state.count} workers — recovering…
          </span>
        </div>
      <% end %>

      <section>
        <h2 class="text-xl font-semibold mb-2">Nodes</h2>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Node</th>
                <th class="text-right">Workers</th>
                <th class="text-right">Callbacks</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={n <- @nodes}>
                <td class="font-mono">{n.node}</td>
                <td class="text-right">{n.worker_count}</td>
                <td class="text-right">{n.callbacks}</td>
                <td>
                  <span class={[
                    "badge",
                    n.status == :live && "badge-success",
                    n.status == :unreachable && "badge-error"
                  ]}>
                    {n.status}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="grid grid-cols-3 gap-4">
        <form phx-submit="spawn" class="card bg-base-200 p-4 space-y-3">
          <h3 class="font-semibold">Spawn subscriptions</h3>
          <%!-- phx-update="ignore" prevents LiveView's diff from overwriting
                user-typed values when the page re-renders on :tick. --%>
          <div id="spawn-form-fields" phx-update="ignore" class="flex flex-wrap gap-2 items-end">
            <label class="form-control">
              <span class="label-text text-xs">Count</span>
              <input
                type="number"
                name="count"
                value="10"
                min="1"
                max={@max_spawn}
                class="input input-bordered input-sm w-20"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs">Interval (s)</span>
              <input
                type="number"
                name="interval_seconds"
                value="5"
                min="1"
                step="1"
                class="input input-bordered input-sm w-20"
              />
            </label>
            <button type="submit" class="btn btn-primary btn-sm">Spawn</button>
          </div>
          <p class="text-xs text-base-content/60">
            Capped at {@max_spawn}. Each subscription POSTs to <code>/api/callbacks/&lt;id&gt;</code>
            on the owner node.
          </p>
        </form>

        <div class="card bg-base-200 p-4 space-y-3">
          <h3 class="font-semibold">Demo controls</h3>
          <div class="flex flex-wrap gap-2">
            <button
              phx-click="inject_chaos"
              disabled={@chaos_state != :idle}
              class="btn btn-error btn-sm"
            >
              Inject Chaos
            </button>
            <button
              phx-click="rolling_deploy"
              disabled={@deploy_state != :idle}
              class="btn btn-accent btn-sm"
            >
              Rolling Deploy
            </button>
          </div>
          <p class="text-xs text-base-content/60">
            <strong>Chaos</strong>: kills every worker on a random node, recovers in ~2.5s.<br />
            <strong>Rolling Deploy</strong>: cordon → drain → uncordon, one node at a time.
          </p>
        </div>

        <div class="card bg-base-200 p-4 space-y-3">
          <h3 class="font-semibold">Reset</h3>
          <button
            phx-click="clear_all"
            class="btn btn-warning btn-sm"
            data-confirm="Unregister every subscription?"
          >
            Clear all subscriptions
          </button>
          <p class="text-xs text-base-content/60">
            Stops every worker on every node and empties the subscriptions table.
          </p>
        </div>
      </section>

      <section>
        <h2 class="text-xl font-semibold mb-2">
          Subscriptions ({@total_subscriptions}) by node
        </h2>
        <div
          class="grid gap-4"
          style={"grid-template-columns: repeat(#{max(length(@nodes), 1)}, minmax(0, 1fr));"}
        >
          <div :for={n <- @nodes} class="card bg-base-200 shadow-sm">
            <div class="card-body p-4 space-y-2">
              <div class="flex items-baseline justify-between">
                <h3 class="font-mono font-semibold text-sm">{n.node}</h3>
                <span class="text-xs text-base-content/60">
                  {n.worker_count} workers · {n.callbacks} callbacks
                </span>
              </div>
              <div class="overflow-y-auto max-h-96">
                <%= if Map.get(@subs_by_node, n.node, []) == [] do %>
                  <p class="text-xs text-base-content/50 italic">no subscriptions</p>
                <% else %>
                  <table class="table table-xs">
                    <thead>
                      <tr>
                        <th>ID</th>
                        <th class="text-right">Interval</th>
                        <th class="text-right">Callbacks</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={s <- Map.get(@subs_by_node, n.node, [])} id={"sub-#{s.id}"}>
                        <td class="font-mono text-xs truncate" title={s.id}>{s.id}</td>
                        <td class="text-right">{format_interval(s.interval_ms)}</td>
                        <td class="text-right">{s.callbacks}</td>
                      </tr>
                    </tbody>
                  </table>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%= if @unassigned_subs != [] do %>
          <div class="mt-4 alert alert-warning">
            <span>
              {length(@unassigned_subs)} subscription(s) have no ring owner (cluster has no live nodes).
            </span>
          </div>
        <% end %>
      </section>
    </div>
    """
  end

  ## Helpers

  defp refresh_state(socket) do
    members = Ring.members()
    stats_by_node = fetch_all_stats(members)
    raw_subs = Heartbeats.list()

    subscriptions = Enum.map(raw_subs, &build_sub_view/1)
    {by_node, unassigned} = group_subs(subscriptions, members)
    nodes = Enum.map(members, &node_summary(&1, stats_by_node, by_node))
    total_callbacks = Enum.reduce(subscriptions, 0, fn s, acc -> acc + s.callbacks end)

    socket
    |> assign(:nodes, nodes)
    |> assign(:subs_by_node, by_node)
    |> assign(:unassigned_subs, unassigned)
    |> assign(:total_subscriptions, length(subscriptions))
    |> assign(:total_callbacks, total_callbacks)
  end

  defp build_sub_view(sub) do
    %{
      id: sub.id,
      callback_url: sub.callback_url,
      interval_ms: sub.interval_ms,
      owner: owner_atom(sub.id),
      callbacks: sub.callbacks_count
    }
  end

  defp group_subs(subscriptions, members) do
    member_set = MapSet.new(members)

    subscriptions
    |> Enum.reduce({%{}, []}, fn sub, {by_node, unassigned} ->
      if sub.owner != nil and MapSet.member?(member_set, sub.owner) do
        {Map.update(by_node, sub.owner, [sub], &(&1 ++ [sub])), unassigned}
      else
        {by_node, [sub | unassigned]}
      end
    end)
    |> then(fn {by_node, unassigned} -> {by_node, Enum.reverse(unassigned)} end)
  end

  defp node_summary(n, stats_by_node, subs_by_node) do
    {worker_count, status} =
      case Map.get(stats_by_node, n) do
        {:ok, %{worker_count: count}} -> {count, :live}
        _other -> {0, :unreachable}
      end

    callbacks =
      subs_by_node
      |> Map.get(n, [])
      |> Enum.reduce(0, fn s, acc -> acc + s.callbacks end)

    %{node: n, worker_count: worker_count, status: status, callbacks: callbacks}
  end

  # One parallel `:erpc.multicall` instead of N sequential `:erpc.call`s, so the
  # LiveView never blocks longer than `@rpc_timeout_ms` total per tick.
  defp fetch_all_stats([]), do: %{}

  defp fetch_all_stats(nodes) do
    results = :erpc.multicall(nodes, Placement, :stats, [], @rpc_timeout_ms)

    nodes
    |> Enum.zip(results)
    |> Map.new(fn
      {node, {:ok, stats}} -> {node, {:ok, stats}}
      {node, _other} -> {node, :unreachable}
    end)
  end

  defp owner_atom(id) do
    case Ring.owner(id) do
      node when is_atom(node) -> node
      _other -> nil
    end
  end

  defp format_interval(ms) when ms >= 1_000, do: "#{div(ms, 1_000)}s"
  defp format_interval(ms), do: "#{ms}ms"
end
