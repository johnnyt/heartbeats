defmodule Heartbeats.ClusterCase do
  @moduledoc """
  ExUnit case template for tests that need a real multi-node Elixir cluster.

  Uses OTP's built-in `:peer` (since OTP 25). Each test sets up N peer nodes,
  loads this project's code path on them, starts the application, connects
  them, and tears them down on exit.

  Tagged `:cluster` and `async: false` because peers are heavyweight (each
  starts the full Phoenix app) and the libring ring is global.

  Usage:

      defmodule My.MultiNodeTest do
        use Heartbeats.ClusterCase, async: false

        @tag :cluster
        test "thing happens across nodes" do
          [a, b] = start_cluster(2)
          :erpc.call(a, Heartbeats, :register, [%{...}])
        end
      end
  """

  use ExUnit.CaseTemplate

  using opts do
    quote do
      use ExUnit.Case, unquote(opts)
      import Heartbeats.ClusterCase
    end
  end

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"primary@127.0.0.1", :longnames)
      Node.set_cookie(:heartbeats_test_cookie)
    end

    :ok
  end

  setup do
    # The runner has the app started too; clear any leftover state so tests
    # see a clean local Subscriptions/WorkerSupervisor.
    clear_runner_state!()

    on_exit(fn ->
      clear_runner_state!()
      # Re-add the runner to its own ring so non-cluster tests still work.
      Heartbeats.Ring.uncordon(Node.self())
    end)

    :ok
  end

  @doc """
  Starts `count` peer nodes, loads the project's compiled code on each,
  starts `:heartbeats`, fully connects them, and waits for libring to settle.

  Returns the list of peer node names.
  """
  @spec start_cluster(pos_integer()) :: [node()]
  def start_cluster(count) when count >= 1 do
    pid_node_pairs =
      for _i <- 1..count do
        start_peer()
      end

    nodes = Enum.map(pid_node_pairs, fn {_pid, node} -> node end)

    # Fully connect every peer to every other peer.
    for n1 <- nodes, n2 <- nodes, n1 != n2 do
      :erpc.call(n1, Node, :connect, [n2])
    end

    # Give libring (which hooks :net_kernel.monitor_nodes) time to settle.
    Process.sleep(300)

    # Remove the test runner from the ring on every node so workers only
    # land on peers — gives tests clean assertions.
    Heartbeats.Ring.cordon(Node.self())

    on_exit_stop_peers(pid_node_pairs)
    nodes
  end

  @doc """
  Starts a single peer node, connects it to the runner and the given existing
  peers, and returns its node name. Re-cordons the runner so it stays out of
  the ring after this peer joins.
  """
  @spec add_peer([node()]) :: node()
  def add_peer(existing_nodes) do
    {peer_pid, node} = start_peer()

    for n <- existing_nodes do
      :erpc.call(node, Node, :connect, [n])
    end

    Process.sleep(300)
    Heartbeats.Ring.cordon(Node.self())

    ExUnit.Callbacks.on_exit(fn ->
      try do
        :peer.stop(peer_pid)
      catch
        _kind, _reason -> :ok
      end
    end)

    node
  end

  @doc "Stops a single peer (used to simulate a node crash)."
  @spec stop_peer(node()) :: :ok
  def stop_peer(node) do
    case :erpc.call(node, :init, :stop, [], 1_000) do
      _result -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Boots one peer node and returns `{peer_pid, node_name}`.

  Most tests want `start_cluster/1` or `add_peer/1` instead — this is exposed
  for tests that need fine control over peer lifecycle (e.g. to test
  graceful shutdown).
  """
  @spec start_peer() :: {pid(), node()}
  def start_peer do
    name = :"peer_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: peer_args()
      })

    # Hand the peer our code paths so it can find compiled beams.
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])

    # Mirror our application env so config (Phoenix endpoint, libring ring,
    # logger, etc.) is identical on the peer.
    for {app, _desc, _vsn} <- Application.loaded_applications() do
      for {key, val} <- Application.get_all_env(app) do
        :erpc.call(node, Application, :put_env, [app, key, val, [persistent: true]])
      end
    end

    # Boot the application on the peer.
    {:ok, _started} = :erpc.call(node, Application, :ensure_all_started, [:heartbeats])

    # Connect the peer to the test runner so subscriptions registered on the
    # peer broadcast to us too (PubSub uses :pg via Erlang distribution).
    true = :erpc.call(node, Node, :connect, [Node.self()])

    {peer, node}
  end

  defp peer_args do
    [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
  end

  defp on_exit_stop_peers(pid_node_pairs) do
    ExUnit.Callbacks.on_exit(fn ->
      for {pid, _node} <- pid_node_pairs do
        try do
          :peer.stop(pid)
        catch
          _kind, _reason -> :ok
        end
      end
    end)
  end

  defp clear_runner_state! do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(Heartbeats.WorkerSupervisor) do
      DynamicSupervisor.terminate_child(Heartbeats.WorkerSupervisor, pid)
    end

    for sub <- Heartbeats.Subscriptions.all() do
      Heartbeats.Subscriptions.delete(sub.id)
    end

    :ok
  end

  @doc """
  Polls `fun` every 25ms until it returns truthy or `timeout` elapses.
  """
  @spec wait_until((-> any()), pos_integer()) :: any()
  def wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    case fun.() do
      result when result not in [false, nil] ->
        result

      _falsy ->
        if System.monotonic_time(:millisecond) >= deadline do
          ExUnit.Assertions.flunk("wait_until timed out")
        else
          Process.sleep(25)
          do_wait(fun, deadline)
        end
    end
  end

  @doc "Returns `Registry.count(Heartbeats.Registry)` on the given node via RPC."
  @spec worker_count(node()) :: non_neg_integer()
  def worker_count(node) do
    :erpc.call(node, Registry, :count, [Heartbeats.Registry])
  end
end
