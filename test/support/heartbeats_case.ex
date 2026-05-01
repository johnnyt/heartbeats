defmodule Heartbeats.Case do
  @moduledoc """
  ExUnit case template for tests that exercise the live `Subscriptions` /
  `Placement` / `WorkerSupervisor` singletons.

  Tests using this case run with `async: false` and clean up workers and
  subscription state in `setup`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Heartbeats.Case
    end
  end

  setup do
    clear_state!()
    on_exit(&clear_state!/0)
    :ok
  end

  @doc """
  Polls `fun` every 10ms until it returns truthy or `timeout` elapses.

  Useful for asserting on async cleanup (e.g. Registry monitors processing
  a process-down event after `DynamicSupervisor.terminate_child/2` returns).
  """
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
  Terminates every running worker and clears the subscriptions ETS table.
  """
  def clear_state! do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Heartbeats.WorkerSupervisor) do
      DynamicSupervisor.terminate_child(Heartbeats.WorkerSupervisor, pid)
    end

    for sub <- Heartbeats.Subscriptions.all() do
      Heartbeats.Subscriptions.delete(sub.id)
    end

    :ok
  end
end
