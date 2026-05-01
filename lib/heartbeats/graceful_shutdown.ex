defmodule Heartbeats.GracefulShutdown do
  @moduledoc """
  Drains this node before the BEAM exits.

  Placed at the **end** of the application supervision tree so its
  `terminate/2` runs **first** when the supervisor stops children in reverse
  order. The drain steps are:

    1. Cordon this node from every member's ring (so peers stop routing new
       work here).
    2. Send `:rebalance` to every local worker. Each worker recomputes its
       owner against the new ring (which excludes us), RPCs the new owner to
       start a replacement worker, then stops itself.
    3. Poll the local worker count until it reaches 0 or the timeout elapses.

  Triggered by:
    * `mix release` SIGTERM handling, which calls `Application.stop(:heartbeats)`.
    * `iex --name a@127.0.0.1 -S mix` followed by `Ctrl-C, a` or `:init.stop()`.
    * Any explicit `Application.stop/1` call.
  """

  use GenServer

  require Logger

  alias Heartbeats.{Placement, Ring, WorkerSupervisor}

  # How often we poll the local worker count while draining.
  @drain_poll_interval_ms 50

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.info("graceful shutdown: draining #{node()}")

    Ring.cordon(node())
    Placement.rebalance_local()

    deadline = System.monotonic_time(:millisecond) + drain_timeout_ms()
    drain_loop(deadline)
  end

  defp drain_timeout_ms do
    Application.get_env(:heartbeats, :drain_timeout_ms, 5_000)
  end

  defp drain_loop(deadline) do
    case local_worker_count() do
      0 ->
        Logger.info("graceful shutdown: drained cleanly")
        :ok

      n ->
        if System.monotonic_time(:millisecond) >= deadline do
          Logger.warning("graceful shutdown: timeout with #{n} workers still local")
          :ok
        else
          Process.sleep(@drain_poll_interval_ms)
          drain_loop(deadline)
        end
    end
  end

  defp local_worker_count do
    DynamicSupervisor.count_children(WorkerSupervisor).active
  rescue
    # Supervisor may already be down by the time we poll on a hard shutdown.
    _error -> 0
  end
end
