defmodule Synthex.Hub.Scorer do
  @moduledoc """
  A `Synthex.Scoring` implementation that distributes the heavy
  `score_bit` workload to a [Synthex Hub](https://synthex.fit) and
  delegates everything else (state collection, validation,
  trajectory exploration) to a local fallback scorer.

  ## Why split

  In the CEGAR loop, only `score_bit` calls are large (50 episodes ×
  thousands of candidates). Everything else (`collect_states`,
  `validate`) is small and fast and runs against the master's local
  Python — no point round-tripping through HTTP for those.

  ## Usage

      scorer =
        Synthex.Hub.Scorer.new(
          env_key: :ant,
          url: "https://synthex.fit/api",
          token: System.fetch_env!("SYNTHEX_HUB_TOKEN")
        )

      Synthex.Gym.Mujoco.solve(:ant, scorer: scorer, ...)

  Defaults are read from `SYNTHEX_HUB_URL` / `SYNTHEX_HUB_TOKEN` env
  vars, so for the canonical hub at synthex.fit you can usually just
  call `Synthex.Hub.Scorer.new(env_key: :ant)`.

  ## Custom fallback

  Pass `:fallback` to override the local scorer used for non-`score_bit`
  commands. Defaults to `Synthex.Scoring.LocalPython.scorer(env_key: env_key)`.
  Useful for tests, dry-runs, or hooking in alternative simulators.
  """

  alias Synthex.Hub.Client

  @doc """
  Build a scorer closure suitable for `Synthex.Gym.Mujoco.solve/2`'s
  `scorer:` opt.

  ## Options

    * `:env_key` — required. Used by the local fallback to find the
      Python oracle script.
    * `:url`, `:token` — passed through to `Synthex.Hub.Client.new/1`.
    * `:chunk_size`, `:poll_interval_ms`, `:request_timeout_ms`,
      `:max_wait_ms` — all forwarded to `Synthex.Hub.Client`.
    * `:batch_name_prefix` — prepended to each batch's auto-generated
      name (used for grouping in the hub's UI).
    * `:fallback` — a `Synthex.Scoring.t()` for non-`score_bit`
      commands. Defaults to `LocalPython` for `env_key`.
  """
  @spec new(keyword()) :: Synthex.Scoring.t()
  def new(opts) do
    env_key = Keyword.fetch!(opts, :env_key)

    client =
      Client.new(
        url: Keyword.get(opts, :url),
        token: Keyword.get(opts, :token),
        chunk_size: Keyword.get(opts, :chunk_size, 100),
        poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 5_000),
        request_timeout_ms: Keyword.get(opts, :request_timeout_ms, 30_000),
        max_wait_ms: Keyword.get(opts, :max_wait_ms, 24 * 60 * 60 * 1000)
      )

    fallback =
      Keyword.get(opts, :fallback) ||
        Synthex.Scoring.LocalPython.scorer(env_key: env_key)

    batch_prefix =
      Keyword.get(
        opts,
        :batch_name_prefix,
        "#{env_key}-#{:erlang.system_time(:second)}"
      )

    fn request -> dispatch(request, client, fallback, batch_prefix) end
  end

  defp dispatch(%{"cmd" => "score_bit"} = request, client, _fallback, batch_prefix) do
    target_bit = request["target_bit"]
    batch_name = "#{batch_prefix}-bit#{target_bit}"

    case Client.score_bit(client, request, batch_name: batch_name) do
      {:ok, %{scores: scores, baseline_reward: baseline}} ->
        {:ok,
         %{
           "scores" => scores,
           "baseline_reward" => baseline,
           "baseline_landings" => 0
         }}

      {:error, reason} ->
        {:error, "Synthex.Hub.Scorer: score_bit batch failed: #{reason}"}
    end
  end

  # Everything else (collect_states, score, explore, ...) is small
  # and stays on the master's local Python. The hub's worker oracle
  # only knows score_bit anyway.
  defp dispatch(request, _client, fallback, _batch_prefix) do
    fallback.(request)
  end
end
