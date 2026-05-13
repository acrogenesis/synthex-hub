import Config

config :server,
  ecto_repos: [Server.Repo]

# Oban queues:
#
#   :chunks  — HTTP-pulled by external workers (concurrency 0,
#              paused). Oban handles persistence, lease/retry/prune.
#   :master  — Server.Workers.Experiment* run the entire CEGAR
#              synthesis loop here, in-process, with checkpoint
#              persistence per accepted bit. ONE master job per
#              experiment at a time (enforced by uniqueness),
#              and these jobs can run for many hours.
#   :system  — short-lived housekeeping (ReapWorkers, ...).
#
# `Lifeline.rescue_after` is sized for the longest-running queue:
# `master` iters can spend an hour or more inside a single
# `Synthex.Hub.Client.score_bit` call when the worker swarm is
# small. The master worker also heartbeats `attempted_at` every
# minute, so a healthy long iter is never reaped; rescue_after is
# the BACKSTOP for actually-crashed jobs.
config :server, Oban,
  repo: Server.Repo,
  queues: [chunks: [limit: 1, paused: true], master: 4, system: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)},
    {Oban.Plugins.Cron, crontab: [
      {"*/5 * * * *", Server.Jobs.ReapWorkers},
      {"*/2 * * * *", Server.Jobs.OrphanReaper}
    ]}
  ]

import_config "#{config_env()}.exs"
