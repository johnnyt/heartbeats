defmodule HeartbeatsWeb.ClusterLiveTest do
  use HeartbeatsWeb.ConnCase, async: false
  use Heartbeats.Case

  import Phoenix.LiveViewTest

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

  describe "demo control banners" do
    test "deploy events drive the rolling-deploy banner through its phases", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(Heartbeats.PubSub, "deploy", {:deploy, {:start, 3}})
      assert render(view) =~ "Starting rolling deploy across 3 nodes"

      Phoenix.PubSub.broadcast(Heartbeats.PubSub, "deploy", {:deploy, {:cordon, :"a@127.0.0.1"}})
      assert render(view) =~ "Cordoning a@127.0.0.1"

      Phoenix.PubSub.broadcast(
        Heartbeats.PubSub,
        "deploy",
        {:deploy, {:draining, :"a@127.0.0.1", 7}}
      )

      assert render(view) =~ "Draining a@127.0.0.1 (7 workers remaining)"

      Phoenix.PubSub.broadcast(
        Heartbeats.PubSub,
        "deploy",
        {:deploy, {:uncordon, :"a@127.0.0.1"}}
      )

      assert render(view) =~ "Uncordoning a@127.0.0.1"

      Phoenix.PubSub.broadcast(Heartbeats.PubSub, "deploy", {:deploy, :complete})
      refute render(view) =~ "Uncordoning"
    end

    test "rolling_deploy with empty ring doesn't crash", %{conn: conn} do
      Heartbeats.Ring.cordon(node())
      on_exit(fn -> Heartbeats.Ring.uncordon(node()) end)

      {:ok, view, _html} = live(conn, ~p"/")

      # The handler returns {:error, :no_nodes} — we just need to confirm
      # it doesn't crash the LiveView.
      _html = render_click(view, "rolling_deploy")
      assert Process.alive?(view.pid)
    end
  end
end
