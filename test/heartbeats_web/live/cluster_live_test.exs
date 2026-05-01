defmodule HeartbeatsWeb.ClusterLiveTest do
  use HeartbeatsWeb.ConnCase, async: false
  use Heartbeats.Case

  import Phoenix.LiveViewTest

  setup do
    Heartbeats.CallbackStats.reset()
    on_exit(&Heartbeats.CallbackStats.reset/0)
    :ok
  end

  test "mounts and renders the empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Heartbeats Cluster"
    assert html =~ "0 subscriptions"
    assert html =~ "Subscriptions (0) by node"
    assert html =~ "no subscriptions"
  end

  test "renders nodes with worker counts", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    # The test runner is the only ring member; it appears as a row.
    assert html =~ Atom.to_string(node())
  end

  test "renders subscriptions after they're registered", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    Heartbeats.register_many(3, %{interval_ms: 60_000})
    # Trigger the PubSub-driven refresh + the subsequent render.
    send(view.pid, :tick)

    html = render(view)
    assert html =~ "3 subscriptions"
    refute html =~ "No subscriptions registered."
  end

  test "spawn event registers the requested number of subscriptions", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> render_submit("spawn", %{"count" => "5", "interval_seconds" => "60"})

    assert Heartbeats.Subscriptions.count() == 5
    assert render(view) =~ "5 subscriptions"
  end

  test "spawn rejects invalid input", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> render_submit("spawn", %{"count" => "5", "interval_seconds" => "0"})

    assert html =~ "interval"
    assert Heartbeats.Subscriptions.count() == 0
  end

  test "clear_all event removes every subscription", %{conn: conn} do
    Heartbeats.register_many(3, %{interval_ms: 60_000})
    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "clear_all")

    assert Heartbeats.Subscriptions.count() == 0
    assert render(view) =~ "0 subscriptions"
  end

  test "callback_received message increments the visible counter", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(
      Heartbeats.PubSub,
      "callbacks",
      {:callback_received, "sub_demo", node(), 1}
    )

    # Give the LiveView a moment to handle the message.
    Process.sleep(50)
    assert render(view) =~ ~r/<span class="font-mono">\s*1/
  end
end
