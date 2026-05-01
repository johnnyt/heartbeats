defmodule HeartbeatsWeb.Router do
  use HeartbeatsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HeartbeatsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HeartbeatsWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api", HeartbeatsWeb do
    pipe_through :api

    get "/subscriptions", SubscriptionController, :index
    post "/subscriptions", SubscriptionController, :create
    delete "/subscriptions/:id", SubscriptionController, :delete

    post "/callbacks/:id", CallbackController, :receive_heartbeat
  end

  # Enable LiveDashboard in development.
  if Application.compile_env(:heartbeats, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HeartbeatsWeb.Telemetry
    end
  end
end
