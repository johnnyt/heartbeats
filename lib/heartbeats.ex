defmodule Heartbeats do
  @moduledoc """
  Public façade for the heartbeats demo.

  The flow when registering a subscription:

      Heartbeats.register/1
        → Subscriptions.put/1   (writes ETS + broadcasts replication)
        → Placement.place/1     (consults Ring, starts/RPCs to owner)
        → WorkerSupervisor.start_worker/1 (DynamicSupervisor on owner node)
        → Worker GenServer      (HTTP heartbeats every ~interval_ms × 0.9)
  """

  alias Heartbeats.{Placement, Ring, Subscription, Subscriptions}

  @doc """
  Registers a new subscription, replicates it across the cluster, and starts
  its heartbeat worker on the ring-determined owner node.

  ## Examples

      iex> {:ok, sub} = Heartbeats.register(%{
      ...>   callback_url: "http://localhost:4100/api/callbacks/demo",
      ...>   interval_ms: 2_000
      ...> })
  """
  @spec register(map()) :: {:ok, Subscription.t()} | {:error, term()}
  def register(attrs) do
    sub = Subscription.new(attrs)
    :ok = Subscriptions.put(sub)

    case Placement.place(sub) do
      {:ok, _pid} -> {:ok, sub}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Registers `count` demo subscriptions in one shot, useful for `iex` sessions
  and manual verification.

  Each subscription gets a unique callback URL of the form
  `http://localhost:4100/api/callbacks/demo_<i>`. Override defaults by passing
  `attrs` (e.g. `%{interval_ms: 2_000}` for faster heartbeats).

  Returns the list of registered subscriptions.

  ## Examples

      iex> subs = Heartbeats.register_many(30)
      iex> length(subs)
      30

      # Faster cadence for a more visible demo:
      iex> Heartbeats.register_many(50, %{interval_ms: 1_500})
  """
  @spec register_many(pos_integer(), map()) :: [Subscription.t()]
  def register_many(count, attrs \\ %{}) when is_integer(count) and count > 0 do
    for _i <- 1..count do
      # Pre-generate the id so we can put it in the callback URL path —
      # otherwise stats keyed by the URL segment wouldn't match `sub.id`
      # in the dashboard.
      id = Subscription.generate_id()

      base = %{
        id: id,
        callback_url: "http://localhost:4100/api/callbacks/#{id}",
        interval_ms: 5_000
      }

      {:ok, sub} = register(Map.merge(base, attrs))
      sub
    end
  end

  @doc "Removes the subscription and stops its worker (wherever it's running)."
  @spec unregister(String.t()) :: :ok
  def unregister(id) when is_binary(id) do
    Placement.unplace(id)
    Subscriptions.delete(id)
  end

  @doc "Returns every subscription known to the cluster."
  @spec list() :: [Subscription.t()]
  def list, do: Subscriptions.all()

  @doc "Removes `node` from the ring on every member; workers there will rebalance off."
  @spec cordon(node()) :: :ok
  def cordon(node \\ Node.self()), do: Ring.cordon(node)

  @doc "Re-adds `node` to the ring on every member; the next rebalance will move work onto it."
  @spec uncordon(node()) :: :ok
  def uncordon(node \\ Node.self()), do: Ring.uncordon(node)
end
