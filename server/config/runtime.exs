import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      Example: postgres://USER:PASS@HOST:5432/DB
      """

  # Default to ssl: true in prod — every hosted Postgres (Neon,
  # Supabase, Fly, RDS) requires it. Override with DATABASE_SSL=false
  # if you're behind a private network where TLS would just add cost.
  ssl_enabled = System.get_env("DATABASE_SSL", "true") == "true"

  ssl_opts =
    if ssl_enabled do
      [verify: :verify_none]
    else
      false
    end

  config :server, Server.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    ssl: ssl_enabled,
    ssl_opts: ssl_opts
end

# Auth token shared with workers. Required in prod, optional in dev.
config :server,
  api_token: System.get_env("API_TOKEN"),
  port: String.to_integer(System.get_env("PORT", "4000")),
  default_chunk_size: String.to_integer(System.get_env("DEFAULT_CHUNK_SIZE", "100")),
  worker_heartbeat_timeout_secs:
    String.to_integer(System.get_env("WORKER_HEARTBEAT_TIMEOUT_SECS", "120"))
