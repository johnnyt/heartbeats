defmodule HeartbeatsWeb.SubscriptionControllerTest do
  use HeartbeatsWeb.ConnCase, async: false
  use Heartbeats.Case

  describe "POST /api/subscriptions" do
    test "creates a subscription and returns its serialized form", %{conn: conn} do
      conn =
        post(conn, ~p"/api/subscriptions", %{
          "callback_url" => "http://localhost:65535/cb",
          "interval_ms" => 5_000
        })

      body = json_response(conn, 201)
      assert String.starts_with?(body["id"], "sub_")
      assert body["callback_url"] == "http://localhost:65535/cb"
      assert body["interval_ms"] == 5_000
      assert is_binary(body["owner_node"])
    end

    test "returns 400 when callback_url is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/subscriptions", %{"interval_ms" => 5_000})
      assert json_response(conn, 400)["error"] =~ "callback_url"
    end

    test "returns 400 when interval_ms is too small", %{conn: conn} do
      conn =
        post(conn, ~p"/api/subscriptions", %{
          "callback_url" => "http://localhost:65535/cb",
          "interval_ms" => 100
        })

      assert json_response(conn, 400)["error"] =~ "interval_ms"
    end
  end

  describe "GET /api/subscriptions" do
    test "lists the registered subscriptions", %{conn: conn} do
      Heartbeats.register_many(3, %{interval_ms: 60_000})

      conn = get(conn, ~p"/api/subscriptions")
      body = json_response(conn, 200)

      assert length(body["subscriptions"]) == 3
      assert Enum.all?(body["subscriptions"], &Map.has_key?(&1, "owner_node"))
    end
  end

  describe "DELETE /api/subscriptions/:id" do
    test "removes the subscription and returns 204", %{conn: conn} do
      {:ok, sub} =
        Heartbeats.register(%{
          callback_url: "http://localhost:65535/cb",
          interval_ms: 60_000
        })

      conn = delete(conn, ~p"/api/subscriptions/#{sub.id}")
      assert response(conn, 204) == ""
      assert Heartbeats.Subscriptions.get(sub.id) == :error
    end
  end
end
