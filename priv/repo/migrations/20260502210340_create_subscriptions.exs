defmodule Heartbeats.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions, primary_key: false) do
      add :id, :string, primary_key: true
      add :callback_url, :string, null: false
      add :interval_ms, :integer, null: false
      add :verifier, :string, null: false
      add :callbacks_count, :integer, default: 0, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
