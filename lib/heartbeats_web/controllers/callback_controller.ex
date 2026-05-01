defmodule HeartbeatsWeb.CallbackController do
  @moduledoc """
  Receives heartbeat callbacks from `Heartbeats.Worker` instances.

  Validates the Apollo callback protocol header, increments the per-id
  counter in `Heartbeats.CallbackStats`, and returns 204. The dashboard
  (Phase 5) subscribes to the `"callbacks"` PubSub topic to render activity.
  """

  use HeartbeatsWeb, :controller

  alias Heartbeats.CallbackStats

  @protocol_header "subscription-protocol"
  @expected_protocol "callback/1.0"

  @spec receive_heartbeat(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def receive_heartbeat(conn, %{"id" => id}) do
    case get_req_header(conn, @protocol_header) do
      [@expected_protocol] ->
        CallbackStats.record(id)
        send_resp(conn, :no_content, "")

      _other ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "missing or invalid #{@protocol_header} header"})
    end
  end
end
