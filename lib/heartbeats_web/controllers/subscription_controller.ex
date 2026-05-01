defmodule HeartbeatsWeb.SubscriptionController do
  use HeartbeatsWeb, :controller

  alias Heartbeats.{Ring, Subscription}

  @doc "Lists every subscription known to the cluster, with each one's current ring owner."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, %{subscriptions: Enum.map(Heartbeats.list(), &serialize/1)})
  end

  @doc """
  Registers a new subscription. Required: `callback_url`.
  Optional: `interval_ms` (default 5_000), `id`, `verifier`.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case Heartbeats.register(params) do
      {:ok, %Subscription{} = sub} ->
        conn
        |> put_status(:created)
        |> json(serialize(sub))

      {:error, :unschedulable} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "no nodes are available in the ring"})
    end
  rescue
    e in ArgumentError ->
      conn
      |> put_status(:bad_request)
      |> json(%{error: Exception.message(e)})
  end

  @doc "Stops the worker and removes the subscription from the cluster."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    :ok = Heartbeats.unregister(id)
    send_resp(conn, :no_content, "")
  end

  defp serialize(%Subscription{} = sub) do
    %{
      id: sub.id,
      callback_url: sub.callback_url,
      interval_ms: sub.interval_ms,
      owner_node: ring_owner(sub.id)
    }
  end

  defp ring_owner(id) do
    case Ring.owner(id) do
      node when is_atom(node) -> Atom.to_string(node)
      _other -> nil
    end
  end
end
