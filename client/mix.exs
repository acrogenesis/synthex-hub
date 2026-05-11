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
      # Master driver — the CSHRL synthesis library. Public repo;
      # override with SYNTHEX_GIT_REF to pin a different commit/tag
      # while debugging. For local development against an unpublished
      # branch, set SYNTHEX_PATH=/abs/path/to/synthex.
      synthex_dep(),
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"}
    ]
  end

  defp synthex_dep do
    case System.get_env("SYNTHEX_PATH") do
      path when is_binary(path) and path != "" ->
        {:synthex, path: path}

      _ ->
        ref = System.get_env("SYNTHEX_GIT_REF", "main")
        {:synthex, git: "https://github.com/doctorcorral/synthex.git", ref: ref}
    end
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
