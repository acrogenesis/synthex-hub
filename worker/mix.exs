defmodule Worker.MixProject do
  use Mix.Project

  def project do
    [
      app: :worker,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Worker.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:broadway, "~> 1.2"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
