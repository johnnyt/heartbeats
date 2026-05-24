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
    * `"deploy"` — banner state for the rolling-deploy controls.

  Polls every second on a `:tick`. Subscription rows + callback counts come
  from a single `Heartbeats.list/0` query (Postgres is shared, so any node
  sees the same rows). Cross-node worker counts come from a parallel
  `:erpc.multicall` to each node's `Placement.stats/0`.
  """

  use HeartbeatsWeb, :live_view

  alias Heartbeats.{Placement, Ring, RollingDeploy}

  @refresh_ms 1_000
  @rpc_timeout_ms 500
  @max_spawn 500

  # How long a yellow ("leaving") or blue ("arrived") highlight stays on a
  # subscription row before fading. Yellow matches Placement's pre-move pause.
  @highlight_ttl_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Heartbeats.PubSub, "subscriptions")
      Phoenix.PubSub.subscribe(Heartbeats.PubSub, "deploy")
      Phoenix.PubSub.subscribe(Heartbeats.PubSub, "placement")
      Process.send_after(self(), :tick, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:max_spawn, @max_spawn)
     |> assign(:deploy_state, :idle)
     |> assign(:highlights, %{})
     |> refresh_state()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, socket |> expire_highlights() |> refresh_state()}
  end

  def handle_info({:put, _sub}, socket), do: {:noreply, refresh_state(socket)}
  def handle_info({:delete, _id}, socket), do: {:noreply, refresh_state(socket)}

  ## Placement (rebalance highlight) lifecycle

  def handle_info({:placement, :leaving, sub_id, from_node, _to_node}, socket) do
    {:noreply,
     socket
     |> put_highlight(sub_id, :yellow, from_node)
     |> refresh_state()}
  end

  def handle_info({:placement, :arrived, sub_id, to_node}, socket) do
    {:noreply,
     socket
     |> put_highlight(sub_id, :blue, to_node)
     |> refresh_state()}
  end

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
                    n.status == :cordoned && "badge-warning",
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

      <section class="card bg-base-200 p-3">
        <div class="flex flex-wrap items-end gap-x-6 gap-y-2">
          <form phx-submit="spawn" class="flex items-end gap-2">
            <%!-- phx-update="ignore" prevents LiveView's diff from overwriting
                  user-typed values when the page re-renders on :tick. --%>
            <div id="spawn-form-fields" phx-update="ignore" class="flex items-end gap-2">
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
          </form>

          <div class="divider divider-horizontal mx-0"></div>

          <button
            phx-click="rolling_deploy"
            disabled={@deploy_state != :idle}
            class="btn btn-accent btn-sm"
            title="Cordon → drain → uncordon, one node at a time."
          >
            Rolling Deploy
          </button>

          <div class="divider divider-horizontal mx-0"></div>

          <button
            phx-click="clear_all"
            class="btn btn-warning btn-sm"
            data-confirm="Unregister every subscription?"
            title="Stops every worker on every node and empties the subscriptions table."
          >
            Clear all
          </button>
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
                      <tr
                        :for={s <- Map.get(@subs_by_node, n.node, [])}
                        id={"sub-#{s.id}"}
                        class={[
                          "transition-colors duration-500",
                          highlight_class(@highlights, s.id)
                        ]}
                      >
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
    member_set = MapSet.new(members)
    visible = Enum.uniq([Node.self() | Node.list()])
    # Include cordoned-but-connected nodes so subs leaving them are still
    # rendered (yellow phase) on a visible card.
    all_nodes = Enum.uniq(members ++ visible)
    stats_by_node = fetch_all_stats(all_nodes)
    raw_subs = Heartbeats.list()
    highlights = socket.assigns[:highlights] || %{}

    subscriptions = Enum.map(raw_subs, &build_sub_view/1)
    {by_node, unassigned} = group_subs(subscriptions, member_set, highlights)
    nodes = Enum.map(all_nodes, &node_summary(&1, stats_by_node, by_node, member_set))
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

  # During a yellow ("leaving") highlight, render the sub at its OLD owner
  # so the audience sees "this is about to move" before the worker actually
  # migrates. Blue and unhighlighted subs use their current ring owner.
  defp group_subs(subscriptions, _member_set, highlights) do
    subscriptions
    |> Enum.reduce({%{}, []}, fn sub, {by_node, unassigned} ->
      display_node = display_owner(sub, highlights)

      if display_node != nil do
        {Map.update(by_node, display_node, [sub], &(&1 ++ [sub])), unassigned}
      else
        {by_node, [sub | unassigned]}
      end
    end)
    |> then(fn {by_node, unassigned} -> {by_node, Enum.reverse(unassigned)} end)
  end

  defp display_owner(sub, highlights) do
    case Map.get(highlights, sub.id) do
      %{state: :yellow, display_node: node} -> node
      _ -> sub.owner
    end
  end

  defp node_summary(n, stats_by_node, subs_by_node, member_set) do
    in_ring? = MapSet.member?(member_set, n)

    {worker_count, status} =
      case Map.get(stats_by_node, n) do
        {:ok, %{worker_count: count}} when in_ring? -> {count, :live}
        {:ok, %{worker_count: count}} -> {count, :cordoned}
        _other when in_ring? -> {0, :unreachable}
        _other -> {0, :cordoned}
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

  ## Highlight management

  defp put_highlight(socket, sub_id, state, display_node) do
    expires_at = System.monotonic_time(:millisecond) + @highlight_ttl_ms

    highlights =
      Map.put(socket.assigns.highlights, sub_id, %{
        state: state,
        display_node: display_node,
        expires_at: expires_at
      })

    assign(socket, :highlights, highlights)
  end

  defp expire_highlights(socket) do
    now = System.monotonic_time(:millisecond)

    highlights =
      socket.assigns.highlights
      |> Enum.reject(fn {_id, %{expires_at: t}} -> t <= now end)
      |> Map.new()

    assign(socket, :highlights, highlights)
  end

  defp highlight_class(highlights, sub_id) do
    case Map.get(highlights, sub_id) do
      %{state: :yellow} -> "bg-warning/30"
      %{state: :blue} -> "bg-info/30"
      _ -> ""
    end
  end
end
