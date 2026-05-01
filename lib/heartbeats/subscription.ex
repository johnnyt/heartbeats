defmodule Heartbeats.Subscription do
  @moduledoc """
  Represents one subscription that needs heartbeats sent to its `callback_url`
  every `interval_ms` milliseconds.

  Mirrors the relevant subset of fields from the Apollo HTTP Callback Protocol.
  """

  @enforce_keys [:id, :callback_url, :interval_ms, :verifier]
  defstruct [:id, :callback_url, :interval_ms, :verifier]

  @type t :: %__MODULE__{
          id: String.t(),
          callback_url: String.t(),
          interval_ms: pos_integer(),
          verifier: String.t()
        }

  @min_interval_ms 500

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    attrs = atomize(attrs)

    %__MODULE__{
      id: Map.get(attrs, :id) || generate_id(),
      callback_url: fetch!(attrs, :callback_url),
      interval_ms: validate_interval!(Map.get(attrs, :interval_ms, 5_000)),
      verifier: Map.get(attrs, :verifier) || generate_verifier()
    }
  end

  defp atomize(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  rescue
    ArgumentError -> attrs
  end

  defp fetch!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> value
      _other -> raise ArgumentError, "missing required field: #{inspect(key)}"
    end
  end

  defp validate_interval!(ms) when is_integer(ms) and ms >= @min_interval_ms, do: ms

  defp validate_interval!(ms) do
    raise ArgumentError,
          "interval_ms must be an integer >= #{@min_interval_ms}, got: #{inspect(ms)}"
  end

  defp generate_id do
    UXID.generate!(prefix: "sub")
  end

  defp generate_verifier do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
