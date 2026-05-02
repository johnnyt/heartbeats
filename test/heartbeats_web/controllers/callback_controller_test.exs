defmodule HeartbeatsWeb.CallbackControllerTest do
  use HeartbeatsWeb.ConnCase, async: false
  use Heartbeats.Case

  alias Heartbeats.Subscriptions

  defp persist!(id) do
    {:ok, sub} =
      Subscriptions.put(%{
        id: id,
        callback_url: "http://localhost:65535/cb",
        interval_ms: 60_000
      })

    sub
  end

  test "POST /api/callbacks/:id with the protocol header increments the counter", %{conn: conn} do
    persist!("sub_test_1")

    conn =
      conn
      |> put_req_header("subscription-protocol", "callback/1.0")
      |> post(~p"/api/callbacks/sub_test_1", %{
        "kind" => "subscription",
        "action" => "check",
        "id" => "sub_test_1",
        "verifier" => "abc123"
      })

    assert response(conn, 204) == ""
    {:ok, sub} = Subscriptions.get("sub_test_1")
    assert sub.callbacks_count == 1
  end

  test "POST without the protocol header returns 400", %{conn: conn} do
    persist!("sub_test_2")

    conn = post(conn, ~p"/api/callbacks/sub_test_2", %{})
    assert json_response(conn, 400)["error"] =~ "subscription-protocol"

    {:ok, sub} = Subscriptions.get("sub_test_2")
    assert sub.callbacks_count == 0
  end

  test "POST with the wrong protocol version returns 400", %{conn: conn} do
    conn =
      conn
      |> put_req_header("subscription-protocol", "callback/2.0")
      |> post(~p"/api/callbacks/sub_test_3", %{})

    assert json_response(conn, 400)["error"] =~ "subscription-protocol"
  end

  test "consecutive POSTs accumulate the counter", %{conn: _conn} do
    persist!("sub_count")

    for _i <- 1..3 do
      build_conn()
      |> put_req_header("subscription-protocol", "callback/1.0")
      |> post(~p"/api/callbacks/sub_count", %{})
    end

    {:ok, sub} = Subscriptions.get("sub_count")
    assert sub.callbacks_count == 3
  end
end
