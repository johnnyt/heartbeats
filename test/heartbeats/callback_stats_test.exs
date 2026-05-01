defmodule Heartbeats.CallbackStatsTest do
  # CallbackStats is a singleton ETS-backed counter; serialize.
  use ExUnit.Case, async: false

  alias Heartbeats.CallbackStats

  setup do
    CallbackStats.reset()
    on_exit(&CallbackStats.reset/0)
    :ok
  end

  test "record/1 increments the counter and returns the new total" do
    assert CallbackStats.record("sub_a") == 1
    assert CallbackStats.record("sub_a") == 2
    assert CallbackStats.record("sub_a") == 3
    assert CallbackStats.count("sub_a") == 3
  end

  test "count/1 returns 0 for unknown ids" do
    assert CallbackStats.count("sub_unknown") == 0
  end

  test "record/1 broadcasts on the callbacks topic" do
    Phoenix.PubSub.subscribe(Heartbeats.PubSub, "callbacks")
    CallbackStats.record("sub_b")
    assert_receive {:callback_received, "sub_b", _node, 1}, 200
  end

  test "all/0 returns a map of every counted id" do
    CallbackStats.record("sub_x")
    CallbackStats.record("sub_x")
    CallbackStats.record("sub_y")

    assert CallbackStats.all() == %{"sub_x" => 2, "sub_y" => 1}
  end

  test "an inbound :increment from a peer node updates the local counter" do
    Phoenix.PubSub.broadcast(
      Heartbeats.PubSub,
      "callbacks_replica",
      {:increment, "sub_remote", :peer@somewhere}
    )

    Process.sleep(50)
    assert CallbackStats.count("sub_remote") == 1
  end

  test "an inbound :increment that originated on this node is ignored" do
    Phoenix.PubSub.broadcast(
      Heartbeats.PubSub,
      "callbacks_replica",
      {:increment, "sub_self", node()}
    )

    Process.sleep(50)
    # No double-counting — the originator already incremented before broadcasting.
    assert CallbackStats.count("sub_self") == 0
  end
end
