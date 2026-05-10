import Config

worker_id =
  System.get_env("WORKER_NAME") ||
    "#{:inet.gethostname() |> elem(1)}-#{:erlang.system_time(:second)}"

pool_size =
  case System.get_env("POOL_SIZE") do
    nil -> System.schedulers_online()
    val -> max(1, String.to_integer(val))
  end

oracle_script =
  System.get_env("ORACLE_SCRIPT") ||
    Path.expand("../environments/gymnasium/oracle_port.py", Path.dirname(__ENV__.file))

config :worker,
  server_url: System.get_env("SERVER_URL", "http://localhost:4000/api"),
  api_token: System.get_env("API_TOKEN"),
  worker_id: worker_id,
  hostname: System.get_env("HOSTNAME", to_string(elem(:inet.gethostname(), 1))),
  pool_size: pool_size,
  python_executable: System.get_env("PYTHON", "python3"),
  oracle_script: oracle_script,
  poll_interval_ms: String.to_integer(System.get_env("POLL_INTERVAL_MS", "2000")),
  heartbeat_interval_ms: String.to_integer(System.get_env("HEARTBEAT_INTERVAL_MS", "30000")),
  request_timeout_ms: String.to_integer(System.get_env("REQUEST_TIMEOUT_MS", "30000"))
