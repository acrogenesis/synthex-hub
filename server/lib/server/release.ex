defmodule Server.Release do
  @moduledoc """
  Helpers invoked from a Mix release via `bin/server eval`.

  Releases don't include `mix`, so we can't run `mix ecto.migrate` in
  production. Instead the deploy entrypoint runs:

      bin/server eval "Server.Release.migrate()"

  before `bin/server start` to bring the schema up.
  """
  @app :server

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
