defmodule Heartbeats.CallbackStats do
  @moduledoc """
  Counts heartbeat callbacks received per subscription, replicated across
  every node in the cluster.

  Backed by an ETS counter table (`:set`, `:public`, `write_concurrency: true`)
  so the controller can `:ets.update_counter` without a GenServer round-trip.

  ### Replication

  Every callback is received on the node bound to the subscription's
  `callback_url` host:port (typically the same node for all callbacks in a
  demo, since all subs target `localhost:4100`). To give every node the same
  cluster-wide view, `record/1` broadcasts an `:increment` message on the
  `"callbacks_replica"` PubSub topic. Every other node's `CallbackStats`
  GenServer applies the increment to its local ETS so counts converge.

  Two topics:

    * `"callbacks_replica"` — internal cross-node ETS sync (originator is
      excluded so it doesn't double-count).
    * `"callbacks"` — public stream for the dashboard, with the new total
      attached. Every node's LiveView subscribes here.
  """

  use GenServer

  @table __MODULE__
  @public_topic "callbacks"
  @replica_topic "callbacks_replica"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Increments the counter for `id` on this node and replicates the increment
  to every peer. Returns the new local count after replication has been
  broadcast.
  """
  @spec record(String.t()) :: non_neg_integer()
  def record(id) when is_binary(id) do
    count = :ets.update_counter(@table, id, {2, 1}, {id, 0})

    Phoenix.PubSub.broadcast(
      Heartbeats.PubSub,
      @replica_topic,
      {:increment, id, node()}
    )

    Phoenix.PubSub.broadcast(
      Heartbeats.PubSub,
      @public_topic,
      {:callback_received, id, node(), count}
    )

    count
  end

  @doc "Returns the local count for `id` (0 if no callbacks received yet)."
  @spec count(String.t()) :: non_neg_integer()
  def count(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, n}] -> n
      [] -> 0
    end
  end

  @doc "Returns a map of `id => local_count` for every subscription with at least one callback."
  @spec all() :: %{String.t() => non_neg_integer()}
  def all do
    @table |> :ets.tab2list() |> Map.new()
  end

  @doc "Resets all counters (useful in tests)."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  ## GenServer

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Phoenix.PubSub.subscribe(Heartbeats.PubSub, @replica_topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:increment, id, originator_node}, state) when is_binary(id) do
    # The originator already incremented locally before broadcasting; only
    # apply the increment on peer nodes.
    if originator_node != node() do
      :ets.update_counter(@table, id, {2, 1}, {id, 0})
    end

    {:noreply, state}
  end
end
