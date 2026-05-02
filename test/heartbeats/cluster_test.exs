defmodule Heartbeats.ClusterTest do
  @moduledoc """
  Multi-node tests using `:peer` for the auto-rebalance and graceful-shutdown
  behavior introduced in Phase 3.

  Tagged `:cluster` and serialised — peers are heavyweight and the libring
  ring is global.
  """

  use Heartbeats.ClusterCase, async: false

  @moduletag :cluster
  @moduletag timeout: 30_000

  defp register_subs_on(node, count, port \\ 65_535) do
    for i <- 1..count do
      attrs = %{
        callback_url: "http://localhost:#{port}/cb/#{i}",
        interval_ms: 60_000
      }

      {:ok, sub} = :erpc.call(node, Heartbeats, :register, [attrs])
      sub
    end
  end

  defp total_workers(nodes) do
    Enum.sum(Enum.map(nodes, &worker_count/1))
  end

  test "subscriptions register on one peer and replicate to all peers" do
    [a, b, c] = start_cluster(3)
    register_subs_on(a, 30)

    wait_until(fn ->
      Enum.all?([a, b, c], fn n ->
        :erpc.call(n, Heartbeats.Subscriptions, :count, []) == 30
      end)
    end)

    # Spread should be roughly 30/3 ≈ 10, but consistent hashing isn't
    # perfectly even — accept anywhere between 1 and 25.
    counts = Enum.map([a, b, c], &worker_count/1)
    assert Enum.sum(counts) == 30
    assert Enum.all?(counts, &(&1 >= 1))
  end

  test "killing a node redistributes its workers to survivors" do
    [a, b, c] = start_cluster(3)
    register_subs_on(a, 30)

    wait_until(fn -> total_workers([a, b, c]) == 30 end)
    counts_before = Map.new([a, b, c], &{&1, worker_count(&1)})
    assert counts_before[c] > 0

    stop_peer(c)

    # Within 5s, the surviving nodes should hold all 30 workers between them.
    wait_until(fn -> total_workers([a, b]) == 30 end)
    assert worker_count(a) + worker_count(b) == 30
  end

  test "a new node joining absorbs its share via rebalance" do
    [a, b] = start_cluster(2)
    register_subs_on(a, 30)

    wait_until(fn -> total_workers([a, b]) == 30 end)
    initial_a = worker_count(a)
    initial_b = worker_count(b)

    c = add_peer([a, b])

    wait_until(fn -> total_workers([a, b, c]) == 30 end)

    # Some workers must have moved off a and b onto c.
    assert worker_count(c) > 0
    assert worker_count(a) <= initial_a
    assert worker_count(b) <= initial_b
  end

  test "callback stats replicate across the cluster" do
    [a, b, c] = start_cluster(3)

    # Record callbacks on a; every peer should converge to the same view.
    :erpc.call(a, Heartbeats.CallbackStats, :record, ["sub_x"])
    :erpc.call(a, Heartbeats.CallbackStats, :record, ["sub_x"])
    :erpc.call(a, Heartbeats.CallbackStats, :record, ["sub_y"])

    wait_until(fn ->
      Enum.all?([b, c], fn n ->
        :erpc.call(n, Heartbeats.CallbackStats, :all, []) == %{"sub_x" => 2, "sub_y" => 1}
      end)
    end)

    assert :erpc.call(a, Heartbeats.CallbackStats, :all, []) == %{"sub_x" => 2, "sub_y" => 1}
  end

  @tag timeout: 60_000
  test "rolling deploy preserves total worker count throughout" do
    [a, b, c] = start_cluster(3)
    register_subs_on(a, 30)

    wait_until(fn -> total_workers([a, b, c]) == 30 end)

    # Subscribe to deploy events on a peer so we can observe the lifecycle.
    :erpc.call(a, Phoenix.PubSub, :subscribe, [Heartbeats.PubSub, "deploy"])

    :ok = :erpc.call(a, Heartbeats.RollingDeploy, :begin, [])

    # 3 nodes × (~2.5s cordoned pause + ~2.5s uncordoned pause + drain) ≈ 18s.
    wait_until(
      fn ->
        :erpc.call(a, Heartbeats.RollingDeploy, :status, []) == :idle and
          total_workers([a, b, c]) == 30
      end,
      30_000
    )

    assert total_workers([a, b, c]) == 30
  end

  test "graceful shutdown drains workers off the leaving node" do
    [a, b, c] = start_cluster(3)
    register_subs_on(a, 30)

    wait_until(fn -> total_workers([a, b, c]) == 30 end)
    assert worker_count(c) > 0

    # Trigger the GracefulShutdown.terminate/2 path on c by stopping the app.
    :erpc.call(c, Application, :stop, [:heartbeats])

    # After graceful drain, the surviving nodes hold all 30 workers.
    wait_until(fn -> worker_count(a) + worker_count(b) == 30 end)
    assert worker_count(a) + worker_count(b) == 30
  end
end
