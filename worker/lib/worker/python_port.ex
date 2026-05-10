defmodule Worker.PythonPort do
  @moduledoc """
  One persistent Python interpreter behind an Erlang Port.

  Crash safety:
    - On port `:exit_status` we reply `{:error, :port_crashed}` to every
      pending caller and stop. The supervisor restarts us → fresh Python.
    - On Python exception, the oracle script writes a JSON `{"error": ...}`
      response so the call returns immediately rather than timing out.
    - Each call has its own monotonic id and a configurable timeout.
  """
  use GenServer
  require Logger

  @default_call_timeout 5 * 60 * 1000

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Synchronously score a chunk payload (must include `cmd` field)."
  def score(name, payload, timeout \\ @default_call_timeout) do
    GenServer.call(name, {:score, payload}, timeout)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = %{port: nil, pending: %{}, buffer: "", opts: opts}
    {:ok, open_port(state)}
  end

  defp open_port(state) do
    python = Application.get_env(:worker, :python_executable, "python3")
    script = Application.get_env(:worker, :oracle_script)
    exe = System.find_executable(python) || raise "python executable not found: #{python}"

    Logger.info("[#{label(state)}] starting #{python} #{script}")

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :stream,
        :use_stdio,
        :exit_status,
        args: ["-u", script]
      ])

    %{state | port: port, buffer: "", pending: %{}}
  end

  @impl true
  def handle_call({:score, payload}, from, state) do
    id = System.unique_integer([:positive])
    payload = Map.put(payload, "job_id", id)

    case Jason.encode(payload) do
      {:ok, json} ->
        Port.command(state.port, json <> "\n")
        {:noreply, %{state | pending: Map.put(state.pending, id, from)}}

      {:error, err} ->
        {:reply, {:error, {:encode_failed, err}}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_buffer = state.buffer <> data
    {lines, remaining} = split_lines(new_buffer)

    pending =
      Enum.reduce(lines, state.pending, fn line, acc ->
        deliver_line(line, acc)
      end)

    {:noreply, %{state | pending: pending, buffer: remaining}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[#{label(state)}] python port exited (status=#{status}); restarting subtree")

    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, {:port_crashed, status}})
    end)

    {:stop, {:port_crashed, status}, %{state | pending: %{}}}
  end

  def handle_info(msg, state) do
    Logger.debug("[#{label(state)}] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    :ok
  end

  def terminate(_, _), do: :ok

  defp deliver_line(line, pending) do
    case Jason.decode(line) do
      {:ok, %{"job_id" => id} = response} ->
        case Map.pop(pending, id) do
          {nil, acc} ->
            Logger.warning("orphan response for job_id=#{id}")
            acc

          {from, acc} ->
            reply =
              cond do
                Map.has_key?(response, "error") -> {:error, response["error"]}
                true -> {:ok, response["results"] || []}
              end

            GenServer.reply(from, reply)
            acc
        end

      {:ok, _other} ->
        Logger.warning("python emitted JSON without job_id: #{line}")
        pending

      {:error, _} ->
        Logger.warning("python emitted non-JSON line: #{line}")
        pending
    end
  end

  defp split_lines(buffer), do: split_lines(buffer, [])

  defp split_lines(buffer, acc) do
    case :binary.split(buffer, "\n") do
      [line, rest] -> split_lines(rest, [line | acc])
      [rest] -> {Enum.reverse(acc), rest}
    end
  end

  defp label(state) do
    case Keyword.get(state.opts, :name, __MODULE__) do
      {:via, _, {_, key}} -> "PythonPort:#{inspect(key)}"
      atom when is_atom(atom) -> "PythonPort:#{inspect(atom)}"
      other -> "PythonPort:#{inspect(other)}"
    end
  end
end
