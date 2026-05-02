defmodule Heartbeats.Subscription do
  @moduledoc """
  Ecto schema for one subscription that needs heartbeats sent to its
  `callback_url` every `interval_ms` milliseconds.

  Mirrors the relevant subset of fields from the Apollo HTTP Callback Protocol.
  `callbacks_count` lives on the row itself — incrementing it on every
  callback receive lets the dashboard show per-sub activity without a
  separate counter store.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @min_interval_ms 500

  @type t :: %__MODULE__{
          id: String.t(),
          callback_url: String.t(),
          interval_ms: pos_integer(),
          verifier: String.t(),
          callbacks_count: non_neg_integer()
        }

  @primary_key {:id, :string, autogenerate: false}
  schema "subscriptions" do
    field(:callback_url, :string)
    field(:interval_ms, :integer)
    field(:verifier, :string)
    field(:callbacks_count, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset for inserting/updating a subscription. Auto-generates
  `id` and `verifier` if not provided.
  """
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(subscription \\ %__MODULE__{}, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> put_default("id", &generate_id/0)
      |> put_default("verifier", &generate_verifier/0)
      |> put_default("interval_ms", fn -> 5_000 end)

    subscription
    |> cast(attrs, [:id, :callback_url, :interval_ms, :verifier])
    |> validate_required([:id, :callback_url, :interval_ms, :verifier])
    |> validate_number(:interval_ms, greater_than_or_equal_to: @min_interval_ms)
  end

  @doc "Generates a UXID-prefixed subscription id."
  @spec generate_id() :: String.t()
  def generate_id do
    UXID.generate!(prefix: "sub", size: :small)
  end

  defp generate_verifier do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp put_default(attrs, key, default_fn) do
    case Map.get(attrs, key) do
      nil -> Map.put(attrs, key, default_fn.())
      "" -> Map.put(attrs, key, default_fn.())
      _other -> attrs
    end
  end
end
