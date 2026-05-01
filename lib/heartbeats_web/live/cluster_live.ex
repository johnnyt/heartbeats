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
    * `"subscriptions"` — register/delete events trigger a full refresh.
    * `"callbacks"` — each callback bumps the inline total counter.

  Polls every second for cross-node worker counts and ring membership
  (the only numbers that need an RPC fan-out — done as one parallel
  `:erpc.multicall` to avoid serialised blocking).
  """

  use HeartbeatsWeb, :live_view

  alias Heartbeats.{CallbackStats, Placement, Ring}

  @refresh_ms 1_000
  @rpc_timeout_ms 500
  @max_spawn 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Heartbeats.PubSub, "subscriptions")
      Phoenix.PubSub.subscribe(Heartbeats.PubSub, "callbacks")
      Process.send_after(self(), :tick, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:max_spawn, @max_spawn)
     |> refresh_state()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, refresh_state(socket)}
  end

  def handle_info({:put, _sub}, socket), do: {:noreply, refresh_state(socket)}
  def handle_info({:delete, _id}, socket), do: {:noreply, refresh_state(socket)}

  def handle_info({:callback_received, _id, _node, _count}, socket) do
    # Bump the cluster-wide counter cheaply; the next :tick will reconcile
    # exact numbers from CallbackStats.
    {:noreply, update(socket, :total_callbacks, &(&1 + 1))}
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
    for sub <- Heartbeats.list(), do: Heartbeats.unregister(sub.id)
    CallbackStats.reset()

    {:noreply,
     socket
     |> put_flash(:info, "Cleared all subscriptions")
     |> refresh_state()}
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

      <section class="grid md:grid-cols-2 gap-4">
        <form phx-submit="spawn" class="card bg-base-200 p-4 space-y-3">
          <h3 class="font-semibold">Spawn subscriptions</h3>
          <%!-- phx-update="ignore" prevents LiveView's diff from overwriting
                user-typed values when the page re-renders on :tick. --%>
          <div id="spawn-form-fields" phx-update="ignore" class="flex gap-2 items-end">
            <label class="form-control">
              <span class="label-text">Count</span>
              <input
                type="number"
                name="count"
                value="10"
                min="1"
                max={@max_spawn}
                class="input input-bordered w-24"
              />
            </label>
            <label class="form-control">
              <span class="label-text">Interval (seconds)</span>
              <input
                type="number"
                name="interval_seconds"
                value="5"
                min="1"
                step="1"
                class="input input-bordered w-32"
              />
            </label>
            <button type="submit" class="btn btn-primary">Spawn</button>
          </div>
          <p class="text-xs text-base-content/60">
            Capped at {@max_spawn}. Each subscription POSTs to <code>/api/callbacks/&lt;id&gt;</code>
            on the owner node.
          </p>
        </form>

        <div class="card bg-base-200 p-4 space-y-3">
          <h3 class="font-semibold">Reset</h3>
          <button
            phx-click="clear_all"
            class="btn btn-warning"
            data-confirm="Unregister every subscription?"
          >
            Clear all subscriptions
          </button>
          <p class="text-xs text-base-content/60">
            Stops every worker, drops every subscription, and resets local callback counters.
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
    callback_counts = CallbackStats.all()
    raw_subs = Heartbeats.list() |> Enum.sort_by(& &1.id)

    subscriptions = Enum.map(raw_subs, &build_sub_view(&1, callback_counts))
    {by_node, unassigned} = group_subs(subscriptions, members)
    nodes = Enum.map(members, &node_summary(&1, stats_by_node, by_node))
    total_callbacks = callback_counts |> Map.values() |> Enum.sum()

    socket
    |> assign(:nodes, nodes)
    |> assign(:subs_by_node, by_node)
    |> assign(:unassigned_subs, unassigned)
    |> assign(:total_subscriptions, length(subscriptions))
    |> assign(:total_callbacks, total_callbacks)
  end

  defp build_sub_view(sub, callback_counts) do
    %{
      id: sub.id,
      callback_url: sub.callback_url,
      interval_ms: sub.interval_ms,
      owner: owner_atom(sub.id),
      callbacks: Map.get(callback_counts, sub.id, 0)
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
