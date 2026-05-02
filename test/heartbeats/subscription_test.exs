defmodule Heartbeats.SubscriptionTest do
  use ExUnit.Case, async: true

  alias Heartbeats.Subscription

  describe "changeset/2" do
    test "auto-generates a UXID-prefixed id when not given" do
      changeset = Subscription.changeset(%{callback_url: "http://example.com/cb"})
      id = Ecto.Changeset.get_field(changeset, :id)
      assert String.starts_with?(id, "sub_")
      assert byte_size(id) > byte_size("sub_")
    end

    test "preserves an explicit id when given" do
      changeset =
        Subscription.changeset(%{id: "sub_explicit", callback_url: "http://example.com/cb"})

      assert Ecto.Changeset.get_field(changeset, :id) == "sub_explicit"
    end

    test "auto-generates a verifier when not given" do
      changeset = Subscription.changeset(%{callback_url: "http://example.com/cb"})
      verifier = Ecto.Changeset.get_field(changeset, :verifier)
      assert is_binary(verifier)
      assert byte_size(verifier) > 0
    end

    test "defaults interval_ms to 5_000 when not given" do
      changeset = Subscription.changeset(%{callback_url: "http://example.com/cb"})
      assert Ecto.Changeset.get_field(changeset, :interval_ms) == 5_000
    end

    test "accepts string-keyed maps" do
      changeset =
        Subscription.changeset(%{
          "callback_url" => "http://example.com/cb",
          "interval_ms" => 1_000
        })

      assert Ecto.Changeset.get_field(changeset, :callback_url) == "http://example.com/cb"
      assert Ecto.Changeset.get_field(changeset, :interval_ms) == 1_000
    end

    test "rejects missing callback_url" do
      changeset = Subscription.changeset(%{interval_ms: 1_000})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset, :callback_url)
    end

    test "rejects interval_ms below 500" do
      changeset =
        Subscription.changeset(%{callback_url: "http://example.com/cb", interval_ms: 100})

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset, :interval_ms), &String.contains?(&1, "500"))
    end
  end

  defp errors_on(changeset, field) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _full, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Map.get(field, [])
  end
end
