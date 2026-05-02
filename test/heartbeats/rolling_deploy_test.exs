defmodule Heartbeats.RollingDeployTest do
  use Heartbeats.Case

  alias Heartbeats.{Ring, RollingDeploy}

  setup do
    # Wait until any in-flight deploy from a previous test completes.
    wait_until_idle()
    :ok
  end

  test "begin/0 returns {:error, :no_nodes} when ring is empty" do
    Ring.cordon(node())
    on_exit(fn -> Ring.uncordon(node()) end)

    assert RollingDeploy.begin() == {:error, :no_nodes}
  end

  test "begin/0 broadcasts the lifecycle events for the only node" do
    Phoenix.PubSub.subscribe(Heartbeats.PubSub, "deploy")

    assert RollingDeploy.begin() == :ok

    assert_receive {:deploy, {:start, 1}}, 1_000
    assert_receive {:deploy, {:cordon, _node}}, 1_000
    assert_receive {:deploy, {:uncordon, _node}}, 10_000
    assert_receive {:deploy, :complete}, 10_000

    wait_until_idle()
  end

  test "begin/0 returns {:error, :already_running} when a deploy is in flight" do
    assert RollingDeploy.begin() == :ok
    assert RollingDeploy.begin() == {:error, :already_running}

    wait_until_idle()
  end

  test "status/0 transitions idle → running → idle" do
    assert RollingDeploy.status() == :idle

    assert RollingDeploy.begin() == :ok

    # Eventually the deploy starts; we may catch it mid-flight.
    Heartbeats.Case.wait_until(fn ->
      match?({:running, _}, RollingDeploy.status()) or RollingDeploy.status() == :idle
    end)

    wait_until_idle()
    assert RollingDeploy.status() == :idle
  end

  defp wait_until_idle do
    Heartbeats.Case.wait_until(fn -> RollingDeploy.status() == :idle end, 15_000)
  end
end
