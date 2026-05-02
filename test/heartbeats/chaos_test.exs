defmodule Heartbeats.ChaosTest do
  use Heartbeats.Case

  alias Heartbeats.{Chaos, Subscription, Subscriptions, Worker, WorkerSupervisor}

  defp build_sub(overrides \\ %{}) do
    Map.merge(
      %{callback_url: "http://localhost:65535/no-listener", interval_ms: 60_000},
      overrides
    )
    |> Subscription.new()
  end

  test "kill_local_workers/0 returns 0 when there are no workers" do
    assert Chaos.kill_local_workers() == 0
  end

  test "kill_local_workers/0 terminates every running worker and returns the count" do
    sub = build_sub()
    Subscriptions.put(sub)
    {:ok, pid} = WorkerSupervisor.start_worker(sub)
    ref = Process.monitor(pid)

    killed = Chaos.kill_local_workers()
    assert killed == 1
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
  end

  test "kill_local_workers/0 triggers a delayed rebalance that re-adopts the orphans" do
    sub = build_sub()
    Subscriptions.put(sub)
    {:ok, original_pid} = WorkerSupervisor.start_worker(sub)
    Phoenix.PubSub.subscribe(Heartbeats.PubSub, "chaos")

    Chaos.kill_local_workers()

    # Recovery is intentionally delayed (~2.5s) so the dashboard shows the
    # downtime window. Wait for the recovered broadcast plus a fresh worker.
    assert_receive {:chaos, :recovered, _node}, 5_000

    Heartbeats.Case.wait_until(fn ->
      case Worker.whereis(sub.id) do
        nil -> false
        pid -> pid != original_pid
      end
    end)
  end

  test "random_kill/0 returns {:error, :no_nodes} when ring is empty" do
    Heartbeats.Ring.cordon(node())
    on_exit(fn -> Heartbeats.Ring.uncordon(node()) end)

    assert Chaos.random_kill() == {:error, :no_nodes}
  end

  test "random_kill/0 broadcasts a chaos event" do
    Phoenix.PubSub.subscribe(Heartbeats.PubSub, "chaos")

    sub = build_sub()
    Subscriptions.put(sub)
    {:ok, _pid} = WorkerSupervisor.start_worker(sub)

    {:ok, %{node: target, killed: killed}} = Chaos.random_kill()
    assert target == node()
    assert killed >= 1
    assert_receive {:chaos, :killed, ^target, _}, 500

    # The replacement worker comes up after the visible recovery delay (~2.5s).
    Heartbeats.Case.wait_until(fn -> Worker.whereis(sub.id) != nil end, 5_000)
  end
end
