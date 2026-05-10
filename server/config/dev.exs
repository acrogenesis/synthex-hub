import Config

config :server, Server.Repo,
  url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/synthex_hub_dev"),
  pool_size: 10,
  log: false

config :logger, level: :info
