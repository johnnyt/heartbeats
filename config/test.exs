import Config

# Configure the test database. Each integration test runs in its own
# transaction (Ecto.Adapters.SQL.Sandbox) so they don't see each other's
# writes.
config :heartbeats, Heartbeats.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "heartbeats_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  show_sensitive_data_on_connection_error: true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :heartbeats, HeartbeatsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "/c/yT4wDZU+/9E1CMZtjLmk0wvGBMeOoj8bbe6GnYEkP3h79cr3912YhQBmFKFdD",
  server: false

# Print only errors during test (heartbeat workers log econnrefused noise
# until Phase 4 wires up a real CallbackController).
config :logger, level: :error

# Keep the graceful-shutdown drain loop snappy in tests.
config :heartbeats, :drain_timeout_ms, 200

# Skip the demo "yellow before move" pause in tests so rebalance stays
# near-instant. Production/dev use the 3s default for visual clarity.
config :heartbeats, :rebalance_yellow_ms, 0

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
