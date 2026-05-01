import Config

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

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
