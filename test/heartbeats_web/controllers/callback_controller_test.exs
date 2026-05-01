defmodule HeartbeatsWeb.CallbackControllerTest do
  use HeartbeatsWeb.ConnCase, async: false

  alias Heartbeats.CallbackStats

  setup do
    CallbackStats.reset()
    on_exit(&CallbackStats.reset/0)
    :ok
  end

  test "POST /api/callbacks/:id with the protocol header increments the counter", %{conn: conn} do
    conn =
      conn
      |> put_req_header("subscription-protocol", "callback/1.0")
      |> post(~p"/api/callbacks/sub_demo", %{
        "kind" => "subscription",
        "action" => "check",
        "id" => "sub_demo",
        "verifier" => "abc123"
      })

    assert response(conn, 204) == ""
    assert CallbackStats.count("sub_demo") == 1
  end

  test "POST without the protocol header returns 400", %{conn: conn} do
    conn = post(conn, ~p"/api/callbacks/sub_demo", %{})
    assert json_response(conn, 400)["error"] =~ "subscription-protocol"
    assert CallbackStats.count("sub_demo") == 0
  end

  test "POST with the wrong protocol version returns 400", %{conn: conn} do
    conn =
      conn
      |> put_req_header("subscription-protocol", "callback/2.0")
      |> post(~p"/api/callbacks/sub_demo", %{})

    assert json_response(conn, 400)["error"] =~ "subscription-protocol"
  end

  test "consecutive POSTs accumulate the counter", %{conn: _conn} do
    for _i <- 1..3 do
      build_conn()
      |> put_req_header("subscription-protocol", "callback/1.0")
      |> post(~p"/api/callbacks/sub_count", %{})
    end

    assert CallbackStats.count("sub_count") == 3
  end
end
