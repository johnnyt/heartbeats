defmodule Heartbeats.PlacementTest do
  use Heartbeats.Case

  alias Heartbeats.{Placement, Subscriptions, Worker}

  defp persist!(overrides \\ %{}) do
    {:ok, sub} =
      Subscriptions.put(
        Map.merge(
          %{callback_url: "http://localhost:65535/no-listener", interval_ms: 60_000},
          overrides
        )
      )

    sub
  end

  test "place/1 starts a local worker registered under the via tuple" do
    sub = persist!()

    assert {:ok, pid} = Placement.place(sub)
    assert Process.alive?(pid)
    assert Worker.whereis(sub.id) == pid
  end

  test "place/1 returns {:error, :unschedulable} when the ring is empty" do
    sub = persist!()

    Heartbeats.Ring.cordon(node())
    on_exit(fn -> Heartbeats.Ring.uncordon(node()) end)

    assert Placement.place(sub) == {:error, :unschedulable}
  end

  test "unplace/1 stops a running worker" do
    sub = persist!()
    {:ok, pid} = Placement.place(sub)
    ref = Process.monitor(pid)

    :ok = Placement.unplace(sub.id)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
    wait_until(fn -> Worker.whereis(sub.id) == nil end)
  end

  test "stats/0 reports local worker count and node" do
    sub = persist!()
    {:ok, _pid} = Placement.place(sub)

    stats = Placement.stats()
    assert stats.node == node()
    assert stats.worker_count >= 1
  end
end
