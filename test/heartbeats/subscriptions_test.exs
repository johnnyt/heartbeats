defmodule Heartbeats.SubscriptionsTest do
  use Heartbeats.Case

  alias Heartbeats.{Subscription, Subscriptions}

  test "put/get/all/count/delete round-trip" do
    sub =
      Subscription.new(%{
        callback_url: "http://example.com/cb",
        interval_ms: 1_000
      })

    :ok = Subscriptions.put(sub)
    assert Subscriptions.get(sub.id) == {:ok, sub}
    assert Subscriptions.count() == 1
    assert Subscriptions.all() == [sub]

    :ok = Subscriptions.delete(sub.id)
    assert Subscriptions.get(sub.id) == :error
    assert Subscriptions.count() == 0
  end

  test "put/1 broadcasts a {:put, sub} message on the subscriptions topic" do
    Phoenix.PubSub.subscribe(Heartbeats.PubSub, "subscriptions")

    sub =
      Subscription.new(%{
        callback_url: "http://example.com/cb",
        interval_ms: 1_000
      })

    :ok = Subscriptions.put(sub)
    assert_receive {:put, ^sub}, 200
  end

  test "delete/1 broadcasts a {:delete, id} message on the subscriptions topic" do
    Phoenix.PubSub.subscribe(Heartbeats.PubSub, "subscriptions")

    sub =
      Subscription.new(%{
        callback_url: "http://example.com/cb",
        interval_ms: 1_000
      })

    :ok = Subscriptions.put(sub)
    :ok = Subscriptions.delete(sub.id)
    assert_receive {:delete, id}, 200
    assert id == sub.id
  end

  test "an inbound {:put, sub} message updates ETS without re-broadcasting" do
    sub =
      Subscription.new(%{
        callback_url: "http://example.com/cb",
        interval_ms: 1_000
      })

    # Simulate a peer node's broadcast arriving here.
    Phoenix.PubSub.broadcast(Heartbeats.PubSub, "subscriptions", {:put, sub})

    # ETS should converge — give the GenServer a tick to process the message.
    Process.sleep(50)
    assert Subscriptions.get(sub.id) == {:ok, sub}
  end
end
