defmodule Heartbeats.RingTest do
  # Operates on a process-global libring ring; serialize.
  use ExUnit.Case, async: false

  alias Heartbeats.Ring

  setup do
    on_exit(fn -> Ring.uncordon(node()) end)
    :ok
  end

  test "this node is a member of the ring by default" do
    assert node() in Ring.members()
  end

  test "owner/1 returns this node when it's the only member" do
    assert Ring.owner("any-key") == node()
  end

  test "cordon/1 removes the node; uncordon/1 re-adds it" do
    Ring.cordon(node())
    refute node() in Ring.members()
    assert Ring.owner("any-key") == {:error, {:invalid_ring, :no_nodes}}

    Ring.uncordon(node())
    assert node() in Ring.members()
    assert Ring.owner("any-key") == node()
  end
end
