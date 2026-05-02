defmodule Heartbeats.Repo do
  use Ecto.Repo,
    otp_app: :heartbeats,
    adapter: Ecto.Adapters.Postgres
end
