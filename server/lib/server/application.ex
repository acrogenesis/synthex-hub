defmodule Server.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:server, :port, 4000)

    children = [
      Server.Repo,
      {Oban, Application.fetch_env!(:server, Oban)},
      {Bandit, plug: Server.Router, port: port}
    ]

    opts = [strategy: :one_for_one, name: Server.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Synthex Hub server listening on :#{port}")
        log_auth_status()
        {:ok, pid}

      err ->
        err
    end
  end

  defp log_auth_status do
    case Application.get_env(:server, :api_token) do
      token when is_binary(token) and byte_size(token) > 0 ->
        Logger.info("API auth: enabled (Bearer token, #{byte_size(token)} bytes)")

      _ ->
        Logger.warning(
          "API auth: DISABLED (no API_TOKEN set). Do not expose this server to the internet."
        )
    end
  end
end
