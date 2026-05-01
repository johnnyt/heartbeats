defmodule Heartbeats.CallbackStats do
  @moduledoc """
  Counts heartbeat callbacks received per subscription on the local node.

  Backed by an ETS counter table (`:set`, `:public`, `write_concurrency: true`)
  so the controller can `:ets.update_counter` without a GenServer round-trip.

  Each `record/1` also broadcasts `{:callback_received, id, node, count}` on
  the `"callbacks"` PubSub topic for the dashboard to consume in Phase 5.
  """

  use GenServer

  @table __MODULE__
  @topic "callbacks"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increments the local counter for `id` and broadcasts the new total."
  @spec record(String.t()) :: non_neg_integer()
  def record(id) when is_binary(id) do
    count = :ets.update_counter(@table, id, {2, 1}, {id, 0})
    Phoenix.PubSub.broadcast(Heartbeats.PubSub, @topic, {:callback_received, id, node(), count})
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
    {:ok, %{}}
  end
end
