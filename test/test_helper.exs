# Bring up Erlang distribution so :peer can spawn peer nodes for the
# multi-node tests. Tagged `:cluster` tests use `Heartbeats.ClusterCase`.
unless Node.alive?() do
  {:ok, _pid} = Node.start(:"primary@127.0.0.1", :longnames)
  Node.set_cookie(:heartbeats_test_cookie)

  # The application booted before distribution came up, so libring's ring
  # still has :nonode@nohost cached. Replace it with the real node name.
  HashRing.Managed.remove_node(:heartbeats, :nonode@nohost)
  HashRing.Managed.add_node(:heartbeats, Node.self())
end

ExUnit.start(exclude: [])
