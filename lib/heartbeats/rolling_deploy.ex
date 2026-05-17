defmodule Heartbeats.RollingDeploy do
  @moduledoc """
  Simulates a Kubernetes-style rolling deploy across the cluster.

  For each ring member, in sequence:

    1. **Cordon** — remove the node from every peer's ring so new placements
       skip it.
    2. **Drain** — RPC `Placement.rebalance_local/0` on the cordoned node so
       its workers self-migrate to other owners. Wait for the local worker
       count to hit zero (or `@drain_timeout_ms`).
    3. **Pause** — hold the cordoned state briefly so the dashboard can
       render it.
    4. **Uncordon** — re-add the node to every peer's ring.
    5. **Settle** — short pause before moving to the next node.

  Broadcasts progress on the `"deploy"` PubSub topic for the dashboard.
  Every message is `{:deploy, event}` where `event` is one of:

      {:start, total_nodes}
      {:cordon, node}
      {:draining, node, remaining_workers}
      {:uncordon, node}
      :complete
      {:error, reason}

  Only one rolling deploy can be in flight at a time.
  """

  use GenServer

  require Logger

  alias Heartbeats.{Placement, Ring}

  @topic "deploy"
  @drain_timeout_ms 5_000
  @drain_poll_ms 100
  # Visible pause between phases so an audience can read each banner.
  # Sized to outlast the dashboard's blue "arrived" highlight (3s TTL) so
  # rows fully fade back to neutral before the next node is cordoned.
  # Total deploy for N nodes ≈ N × (@cordoned_pause_ms + @uncordoned_pause_ms + drain time).
  @cordoned_pause_ms 3_500
  @uncordoned_pause_ms 3_500

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Kicks off a rolling deploy. Returns `:ok` on accept,
  `{:error, :already_running}` if one is in flight, or `{:error, :no_nodes}`
  if the ring is empty.
  """
  @spec begin() :: :ok | {:error, :already_running | :no_nodes}
  def begin, do: GenServer.call(__MODULE__, :begin)

  @doc "Returns the current deploy status: `:idle` or `{:running, current_node}`."
  @spec status() :: :idle | {:running, node() | nil}
  def status, do: GenServer.call(__MODULE__, :status)

  ## GenServer

  @impl true
  def init(_opts), do: {:ok, %{task: nil, current: nil}}

  @impl true
  def handle_call(:begin, _from, %{task: nil} = state) do
    case Ring.members() do
      [] ->
        {:reply, {:error, :no_nodes}, state}

      members ->
        parent = self()
        task = Task.async(fn -> run(members, parent) end)
        {:reply, :ok, %{state | task: task}}
    end
  end

  def handle_call(:begin, _from, state), do: {:reply, {:error, :already_running}, state}

  def handle_call(:status, _from, %{task: nil} = state), do: {:reply, :idle, state}
  def handle_call(:status, _from, state), do: {:reply, {:running, state.current}, state}

  @impl true
  def handle_cast({:current_node, node}, state) do
    {:noreply, %{state | current: node}}
  end

  @impl true
  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil, current: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    if reason != :normal, do: broadcast({:error, reason})
    {:noreply, %{state | task: nil, current: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Deploy script

  defp run(nodes, parent) do
    broadcast({:start, length(nodes)})

    for node <- nodes do
      GenServer.cast(parent, {:current_node, node})
      cordon_drain_uncordon(node)
    end

    GenServer.cast(parent, {:current_node, nil})
    broadcast(:complete)
  end

  defp cordon_drain_uncordon(node) do
    broadcast({:cordon, node})
    Ring.cordon(node)
    # Tiny pause so libring's removal propagates before we ask the cordoned
    # node to rebalance off itself.
    Process.sleep(50)

    broadcast({:draining, node, remote_worker_count(node)})
    :erpc.cast(node, Placement, :rebalance_local, [])
    wait_for_drain(node)

    # Hold the cordoned state visible so an observer can see "node X drained".
    Process.sleep(@cordoned_pause_ms)

    broadcast({:uncordon, node})
    Ring.uncordon(node)

    # Trigger rebalance on every node so workers can migrate **back** to the
    # freshly-uncordoned node. Cordon/uncordon don't fire :nodeup/:nodedown
    # (the node was always connected, just out of the ring), so without this
    # the node would sit empty even though its ring slot is restored.
    rebalance_everywhere()

    # Hold the uncordoned state visible so an observer can see workers
    # migrate back before the next node is cordoned.
    Process.sleep(@uncordoned_pause_ms)
  end

  defp rebalance_everywhere do
    for n <- [Node.self() | Node.list()] do
      :erpc.cast(n, Placement, :rebalance_local, [])
    end
  end

  defp wait_for_drain(node) do
    deadline = System.monotonic_time(:millisecond) + @drain_timeout_ms
    do_wait_for_drain(node, deadline)
  end

  defp do_wait_for_drain(node, deadline) do
    case remote_worker_count(node) do
      0 ->
        :ok

      n ->
        if System.monotonic_time(:millisecond) >= deadline do
          Logger.warning("rolling deploy: drain timed out on #{node} with #{n} workers")
          :timeout
        else
          broadcast({:draining, node, n})
          Process.sleep(@drain_poll_ms)
          do_wait_for_drain(node, deadline)
        end
    end
  end

  defp remote_worker_count(node) do
    case :erpc.call(node, Registry, :count, [Heartbeats.Registry], 1_000) do
      n when is_integer(n) -> n
      _other -> 0
    end
  catch
    _kind, _reason -> 0
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Heartbeats.PubSub, @topic, {:deploy, event})
  end
end
