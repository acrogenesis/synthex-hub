defmodule Server.MixProject do
  use Mix.Project

  def project do
    [
      app: :server,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  defp releases do
    [
      server: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, :tar]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Server.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.15"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:oban, "~> 2.18"}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
