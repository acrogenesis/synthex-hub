defmodule Worker.HttpClient do
  @moduledoc """
  Thin Req wrapper that injects the configured base URL and Bearer
  token, plus a sensible receive timeout. All worker → hub HTTP traffic
  flows through here so auth and timeouts are consistent.
  """

  def get(path, opts \\ []) do
    Req.get(url(path), build_opts(opts))
  end

  def post(path, body, opts \\ []) do
    Req.post(url(path), [json: body] ++ build_opts(opts))
  end

  defp url(path) do
    base = Application.get_env(:worker, :server_url, "http://localhost:4000/api")
    String.trim_trailing(base, "/") <> path
  end

  defp build_opts(opts) do
    headers =
      case Application.get_env(:worker, :api_token) do
        token when is_binary(token) and byte_size(token) > 0 ->
          [{"authorization", "Bearer #{token}"}]

        _ ->
          []
      end

    [
      headers: headers,
      receive_timeout: Application.get_env(:worker, :request_timeout_ms, 30_000),
      retry: false
    ] ++ opts
  end
end
