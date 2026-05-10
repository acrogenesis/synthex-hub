import Config

config :logger, :default_formatter,
  format: "$time [$level] $message\n",
  metadata: []

import_config "#{config_env()}.exs"
