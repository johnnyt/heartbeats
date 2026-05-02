defmodule Heartbeats.Chaos do
  @moduledoc """
  Inject controlled failures for the demo.

  `random_kill/0` picks a random node from the ring and terminates every
  worker on it. The workers don't auto-restart via the DynamicSupervisor
  (we use `terminate_child/2`, not `:kill`, to avoid both the supervisor's
  default `max_restarts: 3 in 5s` cap and a Registry-cleanup race that
  prevents transient restarts from re-registering under the same name).

  After termination we wait `@recovery_delay_ms` (a visible "downtime"
  window) and then cast `Placement.rebalance_local/0` on the same node —
  the Subscriptions ETS still contains every sub, so the local Placement
  adopts the now-orphaned subs and starts fresh workers via the normal
  placement path.

  Visual on the dashboard: the chosen node's worker count dips to 0,
  stays there for ~2.5s while a "chaos in progress" banner shows, then
  rebounds to its previous value as Placement re-adopts.
  """

  require Logger

  alias Heartbeats.{Placement, Ring, WorkerSupervisor}

  @topic "chaos"
  @recovery_delay_ms 2_500

  @doc """
  Picks a random ring member and terminates all of its workers via RPC.

  Returns `{:ok, %{node: target, killed: n}}` or `{:error, :no_nodes}` if
  the ring is empty.
  """
  @spec random_kill() :: {:ok, %{node: node(), killed: non_neg_integer()}} | {:error, :no_nodes}
  def random_kill do
    case Ring.members() do
      [] ->
        {:error, :no_nodes}

      members ->
        target = Enum.random(members)
        killed = remote_kill_local_workers(target)

        Phoenix.PubSub.broadcast(Heartbeats.PubSub, @topic, {:chaos, :killed, target, killed})

        Logger.info("chaos: killed #{killed} workers on #{target}")
        {:ok, %{node: target, killed: killed}}
    end
  end

  @doc """
  Terminates every worker currently registered under this node's
  `WorkerSupervisor` and schedules a delayed `Placement.rebalance_local/0`
  so the orphans are re-adopted after a visible "downtime" window.
  Intended to be called via RPC from `random_kill/0`, but useful directly
  in iex too.
  """
  @spec kill_local_workers() :: non_neg_integer()
  def kill_local_workers do
    children = DynamicSupervisor.which_children(WorkerSupervisor)

    for {_id, pid, _type, _modules} <- children, is_pid(pid) do
      DynamicSupervisor.terminate_child(WorkerSupervisor, pid)
    end

    schedule_recovery()

    length(children)
  end

  defp schedule_recovery do
    Task.start(fn ->
      Process.sleep(@recovery_delay_ms)
      Placement.rebalance_local()

      Phoenix.PubSub.broadcast(
        Heartbeats.PubSub,
        @topic,
        {:chaos, :recovered, node()}
      )
    end)
  end

  defp remote_kill_local_workers(node) do
    if node == Node.self() do
      kill_local_workers()
    else
      try do
        :erpc.call(node, __MODULE__, :kill_local_workers, [], 1_000)
      catch
        _kind, _reason -> 0
      end
    end
  end
end
