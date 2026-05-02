defmodule Heartbeats.DataCase do
  @moduledoc """
  Sets up the Ecto sandbox for tests that touch `Heartbeats.Repo`.

  Pulls in `setup_sandbox/1` from this module if `async: true`. For tests
  that need to share the sandbox with the runtime processes (e.g.
  `Heartbeats.Case` tests where workers and the test interact via DB),
  `async: false` and the connection is set to shared mode.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Heartbeats.DataCase

      alias Heartbeats.Repo
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags. Allow this connection to be
  used across processes (workers, GenServers) when `async: false`.
  """
  @spec setup_sandbox(map()) :: :ok
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Heartbeats.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
