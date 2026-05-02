defmodule Heartbeats.SubscriptionsTest do
  use Heartbeats.Case

  alias Heartbeats.{Subscription, Subscriptions}

  test "put/get/all/count/delete round-trip" do
    {:ok, sub} =
      Subscriptions.put(%{
        callback_url: "http://example.com/cb",
        interval_ms: 1_000
      })

    assert %Subscription{} = sub
    assert {:ok, fetched} = Subscriptions.get(sub.id)
    assert fetched.id == sub.id
    assert Subscriptions.count() == 1

    assert [^fetched] =
             Subscriptions.all()
             |> Enum.map(
               &%{&1 | inserted_at: fetched.inserted_at, updated_at: fetched.updated_at}
             )

    :ok = Subscriptions.delete(sub.id)
    assert Subscriptions.get(sub.id) == :error
    assert Subscriptions.count() == 0
  end

  test "put/1 returns {:error, changeset} for invalid attrs" do
    assert {:error, changeset} = Subscriptions.put(%{interval_ms: 100})
    refute changeset.valid?
  end

  test "put/1 broadcasts a {:put, sub} message on the subscriptions topic" do
    Phoenix.PubSub.subscribe(Heartbeats.PubSub, "subscriptions")

    {:ok, sub} = Subscriptions.put(%{callback_url: "http://example.com/cb", interval_ms: 1_000})

    assert_receive {:put, %Subscription{id: id}}, 200
    assert id == sub.id
  end

  test "delete/1 broadcasts a {:delete, id} message on the subscriptions topic" do
    Phoenix.PubSub.subscribe(Heartbeats.PubSub, "subscriptions")

    {:ok, sub} = Subscriptions.put(%{callback_url: "http://example.com/cb", interval_ms: 1_000})
    :ok = Subscriptions.delete(sub.id)

    assert_receive {:delete, id}, 200
    assert id == sub.id
  end

  test "purge_local/0 stops every locally-running worker" do
    {:ok, sub} = Subscriptions.put(%{callback_url: "http://example.com/cb", interval_ms: 60_000})
    {:ok, pid} = Heartbeats.WorkerSupervisor.start_worker(sub)
    ref = Process.monitor(pid)

    Subscriptions.purge_local()

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500
  end
end
