defmodule Heartbeats.Case do
  @moduledoc """
  ExUnit case template for tests that exercise the live `Placement` /
  `WorkerSupervisor` singletons against the shared Postgres-backed
  `Subscriptions` context.

  Each test runs with the Ecto SQL sandbox in shared mode (so the running
  Worker/Placement processes can see writes from the test process and
  vice versa). Workers and DB rows are torn down in `setup`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Heartbeats.Case

      alias Heartbeats.Repo
    end
  end

  setup tags do
    Heartbeats.DataCase.setup_sandbox(tags)
    clear_state!()
    on_exit(&clear_state!/0)
    :ok
  end

  @doc """
  Builds an unpersisted `%Heartbeats.Subscription{}` struct with sensible
  test defaults. Use this for `Worker` / `Placement` tests that don't need
  the row in the DB. For DB-backed tests, use `Heartbeats.register/1` or
  `Subscriptions.put/1` directly.
  """
  @spec build_sub(map()) :: Heartbeats.Subscription.t()
  def build_sub(overrides \\ %{}) do
    defaults = %{
      id: Heartbeats.Subscription.generate_id(),
      callback_url: "http://localhost:65535/no-listener",
      interval_ms: 60_000,
      verifier: "verifier-#{System.unique_integer([:positive])}",
      callbacks_count: 0
    }

    struct!(Heartbeats.Subscription, Map.merge(defaults, overrides))
  end

  @doc """
  Polls `fun` every 10ms until it returns truthy or `timeout` elapses.

  Useful for asserting on async cleanup (e.g. Registry monitors processing
  a process-down event after `DynamicSupervisor.terminate_child/2` returns).
  """
  @spec wait_until((-> any()), pos_integer()) :: any()
  def wait_until(fun, timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if result = fun.() do
      result
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end

  @doc """
  Terminates every running worker and deletes every subscription row from
  the test DB.
  """
  @spec clear_state!() :: :ok
  def clear_state! do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(Heartbeats.WorkerSupervisor) do
      DynamicSupervisor.terminate_child(Heartbeats.WorkerSupervisor, pid)
    end

    Heartbeats.Repo.delete_all(Heartbeats.Subscription)

    :ok
  end
end
