import Config

config :server, Server.Repo,
  url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/synthex_hub_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :server, Oban, testing: :inline

config :logger, level: :warning
