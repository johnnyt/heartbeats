defmodule Heartbeats.Placement do
  @moduledoc """
  Per-node GenServer that decides where heartbeat workers run and serves as
  the RPC entry point for placement requests from other nodes.

  When `place/1` is called locally:
    - Looks up `Ring.owner(sub.id)`.
    - If the owner is this node, starts the worker via `WorkerSupervisor`.
    - Otherwise, RPCs the same `place/1` request to the owner via
      `GenServer.call({Placement, owner_node}, ...)`.

  Subscribes to `:net_kernel.monitor_nodes/1`. On any `:nodeup` or `:nodedown`,
  schedules a debounced `do_rebalance_local/0` pass which iterates the
  Subscriptions ETS, adopts subs the ring now assigns to us, and tells local
  workers whose owner has changed to migrate themselves.

  Rebalance happens in two phases so the dashboard can animate it:

    1. **Plan + announce** — compute the migrate-off list, broadcast
       `{:placement, :leaving, sub_id, from, to}` per sub on `"placement"`,
       then wait `@rebalance_yellow_ms` so the audience can see the
       "about to move" highlight.
    2. **Apply** — actually call `WorkerSupervisor.start_worker/1` for
       adoptions and `send(pid, :rebalance)` for migrate-offs, broadcasting
       `{:placement, :arrived, sub_id, to_node}` per sub.
  """

  use GenServer

  require Logger

  alias Heartbeats.{Ring, Subscription, Subscriptions, Worker, WorkerSupervisor}

  @placement_topic "placement"

  # Coalesces a flurry of :nodeup/:nodedown events into a single rebalance
  # pass, and gives libring's own monitor_nodes hook a moment to update the
  # ring before we read from it.
  @rebalance_debounce_ms 250

  # How long the "about to move" (yellow) highlight is visible before we
  # actually migrate workers. Slows rebalance for visual clarity in the demo.
  # Overridable via `config :heartbeats, :rebalance_yellow_ms` (tests set 0).
  @rebalance_yellow_ms_default 3_000

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures a worker is running on the ring-determined owner node for `subscription`.

  Returns `{:ok, pid}` (pid is on the owner node, may be remote) or
  `{:error, :unschedulable}` if the ring has no members.
  """
  @spec place(Subscription.t()) :: {:ok, pid()} | {:error, term()}
  def place(%Subscription{} = subscription) do
    case Ring.owner(subscription.id) do
      {:error, {:invalid_ring, :no_nodes}} ->
        {:error, :unschedulable}

      node when node == node() ->
        WorkerSupervisor.start_worker(subscription)

      remote_node ->
        GenServer.call({__MODULE__, remote_node}, {:place, subscription})
    end
  end

  @doc """
  Stops the worker for `subscription_id` wherever it currently runs.

  Best-effort: if the ring no longer maps the id (e.g. ring empty), this is
  a no-op.
  """
  @spec unplace(String.t()) :: :ok
  def unplace(subscription_id) when is_binary(subscription_id) do
    case Ring.owner(subscription_id) do
      {:error, {:invalid_ring, :no_nodes}} ->
        :ok

      node when node == node() ->
        stop_local_worker(subscription_id)

      remote_node ->
        GenServer.call({__MODULE__, remote_node}, {:unplace, subscription_id})
    end
  end

  @doc """
  Sends `:rebalance` to every worker currently running on this node.

  Each worker recomputes its ring owner; if the owner is no longer this node
  it migrates itself to the new owner before stopping.
  """
  @spec rebalance_local() :: :ok
  def rebalance_local do
    GenServer.cast(__MODULE__, :rebalance_local)
  end

  @doc "Returns local placement stats for the dashboard / health checks."
  @spec stats() :: %{worker_count: non_neg_integer(), node: node()}
  def stats do
    %{
      worker_count: DynamicSupervisor.count_children(WorkerSupervisor).active,
      node: Node.self()
    }
  end

  ## GenServer

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    {:ok, %{rebalance_timer: nil, pending_apply: nil}}
  end

  @impl true
  def handle_call({:place, %Subscription{} = sub}, _from, state) do
    {:reply, WorkerSupervisor.start_worker(sub), state}
  end

  def handle_call({:unplace, id}, _from, state) when is_binary(id) do
    stop_local_worker(id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:rebalance_local, state) do
    {:noreply, plan_and_announce(state)}
  end

  @impl true
  def handle_info({:nodeup, _node, _opts}, state) do
    {:noreply, schedule_rebalance(state)}
  end

  def handle_info({:nodedown, _node, _opts}, state) do
    {:noreply, schedule_rebalance(state)}
  end

  def handle_info(:do_rebalance, state) do
    {:noreply, plan_and_announce(%{state | rebalance_timer: nil})}
  end

  def handle_info({:apply_rebalance, plan}, state) do
    apply_plan(plan)
    {:noreply, %{state | pending_apply: nil}}
  end

  ## Helpers

  defp schedule_rebalance(%{rebalance_timer: timer} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    new_timer = Process.send_after(self(), :do_rebalance, @rebalance_debounce_ms)
    %{state | rebalance_timer: new_timer}
  end

  defp plan_and_announce(state) do
    plan = build_plan()

    # Announce the yellow ("leaving") phase before workers actually move.
    for {sub, _pid, to_node} <- plan.migrate do
      broadcast({:placement, :leaving, sub.id, node(), to_node})
    end

    if plan.adopt == [] and plan.migrate == [] do
      state
    else
      if is_reference(state.pending_apply), do: Process.cancel_timer(state.pending_apply)
      ref = Process.send_after(self(), {:apply_rebalance, plan}, yellow_ms())
      %{state | pending_apply: ref}
    end
  end

  defp yellow_ms do
    Application.get_env(:heartbeats, :rebalance_yellow_ms, @rebalance_yellow_ms_default)
  end

  defp build_plan do
    Enum.reduce(Subscriptions.all(), %{adopt: [], migrate: []}, fn sub, acc ->
      case {Ring.owner(sub.id), Worker.whereis(sub.id)} do
        # Owner is us; no local worker yet → adopt.
        {owner, nil} when owner == node() ->
          %{acc | adopt: [sub | acc.adopt]}

        # Owner is us and worker is here; nothing to do.
        {owner, pid} when owner == node() and is_pid(pid) ->
          acc

        # Owner is someone else but worker is here → ask it to migrate.
        {to_node, pid} when is_pid(pid) and is_atom(to_node) ->
          %{acc | migrate: [{sub, pid, to_node} | acc.migrate]}

        # Owner is someone else and we have no worker; not our problem.
        _other ->
          acc
      end
    end)
  end

  defp apply_plan(plan) do
    migrated_in =
      Enum.count(plan.adopt, fn sub ->
        case WorkerSupervisor.start_worker(sub) do
          {:ok, _pid} ->
            broadcast({:placement, :arrived, sub.id, node()})
            true

          {:error, {:already_started, _pid}} ->
            # A peer's migration beat us to it; the worker is here either way.
            broadcast({:placement, :arrived, sub.id, node()})
            true

          _other ->
            false
        end
      end)

    migrated_out =
      Enum.count(plan.migrate, fn {sub, pid, to_node} ->
        if Process.alive?(pid) do
          send(pid, :rebalance)
          broadcast({:placement, :arrived, sub.id, to_node})
          true
        else
          false
        end
      end)

    if migrated_in + migrated_out > 0 do
      Logger.info("rebalance on #{node()}: adopted=#{migrated_in} migrated_off=#{migrated_out}")

      :telemetry.execute(
        [:heartbeats, :placement, :rebalanced],
        %{adopted: migrated_in, migrated_off: migrated_out},
        %{node: node()}
      )
    end

    :ok
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Heartbeats.PubSub, @placement_topic, event)
  end

  defp stop_local_worker(subscription_id) do
    case Worker.whereis(subscription_id) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(WorkerSupervisor, pid)

      nil ->
        :ok
    end
  end
end
