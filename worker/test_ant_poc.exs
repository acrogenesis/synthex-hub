Mix.install([{:jason, "~> 1.4"}])

# Smoke test: spawn one Python port directly (bypassing the pool) and
# score a couple of candidates against Ant-v5.
#
#   mix run test_ant_poc.exs
#
# Useful for debugging the Elixir↔Python protocol without standing up
# the full server / pool / registrar.

defmodule AntPoC do
  def run do
    IO.puts("Starting Python Port (direct, no pool)...")

    Application.put_env(:worker, :python_executable, System.get_env("PYTHON", "python3"))

    Application.put_env(
      :worker,
      :oracle_script,
      Path.expand("environments/gymnasium/oracle_port.py")
    )

    {:ok, _pid} = Worker.PythonPort.start_link(name: :test_port)

    payload = %{
      "cmd" => "score_bit",
      "env_name" => "Ant-v5",
      "bits_per_dim" => 3,
      "max_steps" => 10,
      "target_bit" => 0,
      "seeds" => [42],
      "bit_predicates" => List.duplicate("falsep", 24),
      "candidates" => [
        ["feat", ["axis", 0, 0.5]],
        ["feat", ["diag", 0, 1, 1.0]]
      ]
    }

    IO.puts("Calling score/3...")

    case Worker.PythonPort.score(:test_port, payload, 30_000) do
      {:ok, results} ->
        IO.puts("\n=== Results ===")
        IO.inspect(results, pretty: true)

      {:error, reason} ->
        IO.puts("\n=== Error ===")
        IO.inspect(reason, pretty: true)
    end
  end
end

AntPoC.run()
