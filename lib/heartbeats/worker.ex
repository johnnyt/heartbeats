defmodule Heartbeats.Worker do
  @moduledoc """
  GenServer that emits heartbeats for one `Heartbeats.Subscription`.

  Sends an HTTP POST to the subscription's `callback_url` every ~90% of
  `interval_ms` (10% grace), per the Apollo HTTP Callback Protocol shape.

  On `:rebalance`, recomputes its ring owner and migrates itself if the owner
  has changed: it asks the new owner's `Heartbeats.Placement` to start a fresh
  worker, then `{:stop, {:shutdown, :rebalanced}, state}`.
  """

  use GenServer, restart: :transient

  require Logger

  alias Heartbeats.{Ring, Subscription}

  @callback_protocol_header {"subscription-protocol", "callback/1.0"}

  @spec start_link(Subscription.t()) :: GenServer.on_start()
  def start_link(%Subscription{} = subscription) do
    GenServer.start_link(__MODULE__, subscription, name: via_tuple(subscription.id))
  end

  @doc "Looks up the locally-running worker pid for `subscription_id`, if any."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(subscription_id) when is_binary(subscription_id) do
    case Registry.lookup(Heartbeats.Registry, {:worker, subscription_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Returns a `:via` tuple for registering/looking up workers by subscription id."
  @spec via_tuple(String.t()) :: {:via, Registry, {Heartbeats.Registry, {:worker, String.t()}}}
  def via_tuple(subscription_id) when is_binary(subscription_id) do
    {:via, Registry, {Heartbeats.Registry, {:worker, subscription_id}}}
  end

  ## GenServer

  @impl true
  def init(%Subscription{} = subscription) do
    :telemetry.execute(
      [:heartbeats, :worker, :placed],
      %{count: 1},
      %{id: subscription.id, node: Node.self()}
    )

    send(self(), :send_heartbeat)
    {:ok, %{subscription: subscription}}
  end

  @impl true
  def handle_info(:send_heartbeat, %{subscription: sub} = state) do
    send_heartbeat(sub)
    schedule_next(sub.interval_ms)
    {:noreply, state}
  end

  def handle_info(:rebalance, %{subscription: sub} = state) do
    case Ring.owner(sub.id) do
      node when node == node() ->
        {:noreply, state}

      {:error, {:invalid_ring, :no_nodes}} ->
        # No ring members at all — nothing to do but stay put.
        {:noreply, state}

      new_owner ->
        Logger.info("rebalancing #{sub.id} from #{node()} to #{new_owner}")

        :telemetry.execute(
          [:heartbeats, :worker, :rebalanced],
          %{count: 1},
          %{id: sub.id, from: node(), to: new_owner}
        )

        # Ask the new owner's Placement to start a worker for this subscription
        # before we stop, so there's no gap.
        try do
          GenServer.call({Heartbeats.Placement, new_owner}, {:place, sub})
        catch
          :exit, reason ->
            Logger.warning("failed to reschedule #{sub.id} to #{new_owner}: #{inspect(reason)}")
        end

        {:stop, {:shutdown, :rebalanced}, state}
    end
  end

  ## Helpers

  defp send_heartbeat(%Subscription{} = sub) do
    payload = %{
      kind: "subscription",
      action: "check",
      id: sub.id,
      verifier: sub.verifier
    }

    case Req.post(sub.callback_url,
           headers: [@callback_protocol_header],
           json: payload,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :telemetry.execute(
          [:heartbeats, :worker, :sent],
          %{count: 1},
          %{id: sub.id, node: Node.self(), status: status}
        )

      {:ok, %{status: status}} ->
        Logger.warning("heartbeat for #{sub.id} returned status #{status}")

        :telemetry.execute(
          [:heartbeats, :worker, :failed],
          %{count: 1},
          %{id: sub.id, node: Node.self(), reason: {:status, status}}
        )

      {:error, reason} ->
        Logger.warning("heartbeat for #{sub.id} failed: #{inspect(reason)}")

        :telemetry.execute(
          [:heartbeats, :worker, :failed],
          %{count: 1},
          %{id: sub.id, node: Node.self(), reason: reason}
        )
    end
  end

  defp schedule_next(interval_ms) do
    grace = div(interval_ms, 10)
    delay = interval_ms - grace
    Process.send_after(self(), :send_heartbeat, delay)
  end
end
