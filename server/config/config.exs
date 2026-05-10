import Config

config :server,
  ecto_repos: [Server.Repo]

# Oban: chunks queue runs at concurrency 0 because chunks are HTTP-pulled by
# external workers, not executed in-process. Oban manages persistence,
# leases (via Lifeline), idempotency, retries, and pruning.
config :server, Oban,
  repo: Server.Repo,
  queues: [chunks: [limit: 1, paused: true], system: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(15)},
    {Oban.Plugins.Cron, crontab: [
      {"*/5 * * * *", Server.Jobs.ReapWorkers}
    ]}
  ]

import_config "#{config_env()}.exs"
