defmodule Heartbeats.WorkerTest do
  use Heartbeats.Case

  alias Heartbeats.{Subscription, Subscriptions, Worker, WorkerSupervisor}

  defp build_sub(overrides \\ %{}) do
    Map.merge(
      %{callback_url: "http://localhost:65535/no-listener", interval_ms: 60_000},
      overrides
    )
    |> Subscription.new()
  end

  test "via_tuple/1 builds a Registry-backed name" do
    assert {:via, Registry, {Heartbeats.Registry, {:worker, "sub_abc"}}} =
             Worker.via_tuple("sub_abc")
  end

  test "whereis/1 returns nil when no worker is registered" do
    assert Worker.whereis("sub_does_not_exist") == nil
  end

  test ":rebalance is a no-op when this node is still the owner" do
    sub = build_sub()
    Subscriptions.put(sub)
    {:ok, pid} = WorkerSupervisor.start_worker(sub)

    send(pid, :rebalance)

    # Process should still be alive after handling :rebalance.
    Process.sleep(50)
    assert Process.alive?(pid)
    assert Worker.whereis(sub.id) == pid
  end

  test ":rebalance with an empty ring keeps the worker in place" do
    sub = build_sub()
    Subscriptions.put(sub)
    {:ok, pid} = WorkerSupervisor.start_worker(sub)

    Heartbeats.Ring.cordon(node())
    on_exit(fn -> Heartbeats.Ring.uncordon(node()) end)

    send(pid, :rebalance)
    Process.sleep(50)
    assert Process.alive?(pid)
  end
end
