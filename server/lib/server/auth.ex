defmodule Server.Auth do
  @moduledoc """
  Plug for shared-token bearer auth on `/api/*` routes.

  Set `API_TOKEN` env var on the server and the same value on each worker.
  Requests must send `Authorization: Bearer <token>` (or `?token=<token>`
  fallback for quick curl debugging). When `API_TOKEN` is unset (dev),
  auth is skipped.
  """
  import Plug.Conn

  # Routes that need to be reachable without auth: health checks, the
  # public landing page, the worker installer script, and the
  # aggregate stats counter that drives the landing page.
  @public_paths ~w(
    /
    /health
    /install
    /install.sh
    /index.html
    /favicon.ico
    /robots.txt
    /api/public-status
  )

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: path} = conn, _opts) when path in @public_paths,
    do: conn

  def call(conn, _opts) do
    case configured_token() do
      nil ->
        conn

      "" ->
        conn

      expected ->
        if valid?(conn, expected) do
          conn
        else
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
          |> halt()
        end
    end
  end

  defp valid?(conn, expected) do
    presented =
      get_req_header(conn, "authorization")
      |> List.first()
      |> case do
        "Bearer " <> token -> token
        "bearer " <> token -> token
        _ -> nil
      end

    presented = presented || conn.params["token"]

    is_binary(presented) and Plug.Crypto.secure_compare(presented, expected)
  end

  defp configured_token do
    Application.get_env(:server, :api_token)
  end
end
