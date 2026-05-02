defmodule HeartbeatsWeb.CallbackController do
  @moduledoc """
  Receives heartbeat callbacks from `Heartbeats.Worker` instances.

  Validates the Apollo callback protocol header, then increments the row's
  `callbacks_count` column via a single `Repo.update_all/3`. The dashboard
  polls the DB on its 1s tick and renders the updated counts.
  """

  use HeartbeatsWeb, :controller

  import Ecto.Query, warn: false

  alias Heartbeats.{Repo, Subscription}

  @protocol_header "subscription-protocol"
  @expected_protocol "callback/1.0"

  @spec receive_heartbeat(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def receive_heartbeat(conn, %{"id" => id}) do
    case get_req_header(conn, @protocol_header) do
      [@expected_protocol] ->
        Repo.update_all(
          from(s in Subscription, where: s.id == ^id),
          inc: [callbacks_count: 1]
        )

        send_resp(conn, :no_content, "")

      _other ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "missing or invalid #{@protocol_header} header"})
    end
  end
end
