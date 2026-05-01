defmodule Heartbeats.GracefulShutdownTest do
  @moduledoc """
  Single-node tests for `Heartbeats.GracefulShutdown`. Drain timeout is set
  to 200ms in `config/test.exs` so these stay fast. The full graceful-drain
  scenario across a real cluster is in `Heartbeats.ClusterTest`.
  """

  use Heartbeats.Case

  alias Heartbeats.{GracefulShutdown, Ring}

  setup do
    on_exit(fn -> Ring.uncordon(node()) end)
    :ok
  end

  test "terminate/2 cordons this node from the ring" do
    GracefulShutdown.terminate(:shutdown, %{})
    refute node() in Ring.members()
  end

  test "terminate/2 returns :ok when there are no local workers" do
    assert GracefulShutdown.terminate(:shutdown, %{}) == :ok
  end

  test "terminate/2 returns :ok even if drain times out (single-node, nowhere to migrate)" do
    sub =
      Heartbeats.Subscription.new(%{
        callback_url: "http://localhost:65535/x",
        interval_ms: 60_000
      })

    Heartbeats.Subscriptions.put(sub)
    {:ok, _pid} = Heartbeats.WorkerSupervisor.start_worker(sub)

    # Cordoning the only node leaves the worker no place to migrate to.
    # terminate/2 should still return cleanly after the drain timeout.
    assert GracefulShutdown.terminate(:shutdown, %{}) == :ok
  end
end
