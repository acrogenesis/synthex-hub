defmodule SynthexHubClient.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :synthex_hub_client,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Master driver — your synthesis loop. Pulled by path so this lib
      # works against an arbitrary local checkout. Swap for `git:` if
      # you ever publish synthex.
      {:synthex, path: System.get_env("SYNTHEX_PATH", "../../synthex")},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end

  defp description do
    """
    Master-side client for the Synthex Hub: HTTP submit/poll, plus
    a `Synthex.Hub.Scorer` that plugs into `Synthex.Gym.Mujoco.solve/2`
    to distribute candidate evaluation across a swarm of workers.
    """
  end

  defp package do
    [
      maintainers: ["doctorcorral"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/doctorcorral/synthex-hub"}
    ]
  end
end
