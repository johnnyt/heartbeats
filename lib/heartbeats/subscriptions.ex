defmodule Heartbeats.Subscriptions do
  @moduledoc """
  Subscriptions context — thin wrapper around `Heartbeats.Repo` for the
  `subscriptions` table.

  Every node connects to the same Postgres database, so this module needs
  no replication machinery: it's the source of truth.

  `put/1` and `delete/1` broadcast `{:put, sub}` / `{:delete, id}` on the
  `"subscriptions"` PubSub topic so the live dashboard refreshes
  immediately when a sub is registered or unregistered. The dashboard
  polls every second anyway, but the broadcast removes the lag for the
  user-triggered events.

  `purge_local/0` is the per-node cleanup half of `Heartbeats.clear_all/0`
  — it terminates every locally-running worker. The DB-level
  `Repo.delete_all/1` runs once from the calling node.
  """

  import Ecto.Query, warn: false

  alias Heartbeats.{Repo, Subscription}

  @topic "subscriptions"

  @spec put(map() | Subscription.t()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def put(attrs) when is_map(attrs) and not is_struct(attrs, Subscription) do
    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :id)
    |> case do
      {:ok, sub} = ok ->
        Phoenix.PubSub.broadcast(Heartbeats.PubSub, @topic, {:put, sub})
        ok

      {:error, _changeset} = error ->
        error
    end
  end

  def put(%Subscription{} = sub) do
    put(Map.from_struct(sub))
  end

  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    Repo.delete_all(from(s in Subscription, where: s.id == ^id))
    Phoenix.PubSub.broadcast(Heartbeats.PubSub, @topic, {:delete, id})
    :ok
  end

  @spec get(String.t()) :: {:ok, Subscription.t()} | :error
  def get(id) when is_binary(id) do
    case Repo.get(Subscription, id) do
      nil -> :error
      %Subscription{} = sub -> {:ok, sub}
    end
  end

  @spec all() :: [Subscription.t()]
  def all do
    Repo.all(from(s in Subscription, order_by: s.id))
  end

  @spec count() :: non_neg_integer()
  def count, do: Repo.aggregate(Subscription, :count, :id)

  @doc """
  Stops every locally-running worker. Called via `:erpc.multicall` from
  `Heartbeats.clear_all/0` so each node tears down its own workers
  before the cluster-wide `Repo.delete_all/1` runs.
  """
  @spec purge_local() :: :ok
  def purge_local do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(Heartbeats.WorkerSupervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Heartbeats.WorkerSupervisor, pid)
    end

    :ok
  end
end
