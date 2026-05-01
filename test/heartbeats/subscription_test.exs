defmodule Heartbeats.SubscriptionTest do
  use ExUnit.Case, async: true

  alias Heartbeats.Subscription

  describe "new/1" do
    test "generates a UXID-prefixed id when none is given" do
      sub = Subscription.new(%{callback_url: "http://example.com/cb", interval_ms: 1_000})
      assert String.starts_with?(sub.id, "sub_")
      # UXID payload after prefix is 26 chars
      assert byte_size(sub.id) == byte_size("sub_") + 26
    end

    test "preserves an explicit id when given" do
      sub =
        Subscription.new(%{
          id: "sub_explicit",
          callback_url: "http://example.com/cb",
          interval_ms: 1_000
        })

      assert sub.id == "sub_explicit"
    end

    test "generates a verifier when none is given" do
      sub = Subscription.new(%{callback_url: "http://example.com/cb", interval_ms: 1_000})
      assert is_binary(sub.verifier)
      assert byte_size(sub.verifier) > 0
    end

    test "accepts string-keyed maps" do
      sub = Subscription.new(%{"callback_url" => "http://example.com/cb", "interval_ms" => 1_000})
      assert sub.callback_url == "http://example.com/cb"
      assert sub.interval_ms == 1_000
    end

    test "rejects missing callback_url" do
      assert_raise ArgumentError, ~r/callback_url/, fn ->
        Subscription.new(%{interval_ms: 1_000})
      end
    end

    test "rejects interval_ms below 500" do
      assert_raise ArgumentError, ~r/interval_ms/, fn ->
        Subscription.new(%{callback_url: "http://example.com/cb", interval_ms: 100})
      end
    end
  end
end
