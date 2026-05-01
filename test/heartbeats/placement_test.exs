defmodule Heartbeats.PlacementTest do
  use Heartbeats.Case

  alias Heartbeats.{Placement, Subscription, Subscriptions, Worker}

  defp build_sub(overrides \\ %{}) do
    Map.merge(
      %{callback_url: "http://localhost:65535/no-listener", interval_ms: 60_000},
      overrides
    )
    |> Subscription.new()
  end

  test "place/1 starts a local worker registered under the via tuple" do
    sub = build_sub()
    Subscriptions.put(sub)

    assert {:ok, pid} = Placement.place(sub)
    assert Process.alive?(pid)
    assert Worker.whereis(sub.id) == pid
  end

  test "place/1 returns {:error, :unschedulable} when the ring is empty" do
    sub = build_sub()
    Subscriptions.put(sub)

    Heartbeats.Ring.cordon(node())
    on_exit(fn -> Heartbeats.Ring.uncordon(node()) end)

    assert Placement.place(sub) == {:error, :unschedulable}
  end

  test "unplace/1 stops a running worker" do
    sub = build_sub()
    Subscriptions.put(sub)

    {:ok, pid} = Placement.place(sub)
    ref = Process.monitor(pid)

    :ok = Placement.unplace(sub.id)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
    wait_until(fn -> Worker.whereis(sub.id) == nil end)
  end

  test "stats/0 reports local worker count and node" do
    sub = build_sub()
    Subscriptions.put(sub)
    {:ok, _pid} = Placement.place(sub)

    stats = Placement.stats()
    assert stats.node == node()
    assert stats.worker_count >= 1
  end
end
