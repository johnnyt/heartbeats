defmodule HeartbeatsTest do
  use Heartbeats.Case

  alias Heartbeats.{Subscriptions, Worker}

  test "register/1 stores the subscription and starts a worker on the owner node" do
    {:ok, sub} =
      Heartbeats.register(%{
        callback_url: "http://localhost:65535/no-listener",
        interval_ms: 60_000
      })

    assert String.starts_with?(sub.id, "sub_")
    assert {:ok, ^sub} = Subscriptions.get(sub.id)
    assert is_pid(Worker.whereis(sub.id))
  end

  test "register_many/2 registers N subscriptions with default callback URLs" do
    subs = Heartbeats.register_many(5, %{interval_ms: 60_000})

    assert length(subs) == 5
    assert Enum.all?(subs, &String.starts_with?(&1.id, "sub_"))
    assert Enum.uniq_by(subs, & &1.id) == subs

    callback_urls = Enum.map(subs, & &1.callback_url)
    assert Enum.uniq(callback_urls) == callback_urls

    assert Enum.all?(
             callback_urls,
             &String.starts_with?(&1, "http://localhost:4100/api/callbacks/")
           )

    assert Heartbeats.Subscriptions.count() == 5
  end

  test "list/0 returns all registered subscriptions" do
    {:ok, sub_a} =
      Heartbeats.register(%{
        callback_url: "http://localhost:65535/a",
        interval_ms: 60_000
      })

    {:ok, sub_b} =
      Heartbeats.register(%{
        callback_url: "http://localhost:65535/b",
        interval_ms: 60_000
      })

    ids = Heartbeats.list() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == Enum.sort([sub_a.id, sub_b.id])
  end

  test "unregister/1 deletes the subscription and stops its worker" do
    {:ok, sub} =
      Heartbeats.register(%{
        callback_url: "http://localhost:65535/no-listener",
        interval_ms: 60_000
      })

    pid = Worker.whereis(sub.id)
    ref = Process.monitor(pid)

    :ok = Heartbeats.unregister(sub.id)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500
    wait_until(fn -> Worker.whereis(sub.id) == nil end)
    assert Subscriptions.get(sub.id) == :error
  end
end
