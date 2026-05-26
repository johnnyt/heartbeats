defmodule Heartbeats.Ring do
  @moduledoc """
  Thin wrapper around `libring`'s managed ring, named `:heartbeats`.

  The ring itself is owned by `libring` (configured in `config/config.exs` with
  `monitor_nodes: true`), which keeps membership in sync with `Node.list/0`
  automatically. This module exposes the only operations the rest of the app
  cares about: looking up the owning node for a key, listing members, and
  cordoning/uncordoning a node (e.g. for graceful drain during a rolling deploy).
  """

  @ring :heartbeats

  @type owner_result :: node() | {:error, {:invalid_ring, :no_nodes}}

  @doc """
  Returns the node responsible for `key` according to the consistent hash ring.

  Returns `{:error, {:invalid_ring, :no_nodes}}` if the ring has no members
  (e.g. during boot before any node has joined).
  """
  @spec owner(term()) :: owner_result()
  def owner(key), do: HashRing.Managed.key_to_node(@ring, key)

  @doc "Returns the list of nodes currently in the ring."
  @spec members() :: [node()]
  def members, do: HashRing.Managed.nodes(@ring)

  @doc """
  Removes `node` from the ring on every member of the cluster.

  Use this to drain a node before shutdown or to simulate it being unavailable
  during a rolling deploy. After this call, `owner/1` on any node will hash
  keys onto the remaining members.
  """
  @spec cordon(node()) :: :ok
  def cordon(node) do
    multicall(:remove_node, [node])
  end

  @doc "Re-adds `node` to the ring on every member."
  @spec uncordon(node()) :: :ok
  def uncordon(node) do
    multicall(:add_node, [node])
  end

  defp multicall(fun, args) do
    nodes = [Node.self() | Node.list()]
    :erpc.multicall(nodes, HashRing.Managed, fun, [@ring | args])
    :ok
  end
end
