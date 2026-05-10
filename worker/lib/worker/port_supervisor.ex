defmodule Worker.PortSupervisor do
  @moduledoc """
  Supervises N persistent Python ports under `Worker.PortRegistry`,
  one per CPU core (configured via `:worker, :pool_size`).

  Each port is a `Worker.PythonPort` GenServer registered as
  `{:port, idx}`. Crashes are restarted independently — the rest of
  the pool keeps working.
  """
  use Supervisor
  require Logger

  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    pool_size = Application.get_env(:worker, :pool_size, 1)
    Logger.info("[Ports] starting #{pool_size} python port(s)")

    children =
      [{Registry, keys: :unique, name: Worker.PortRegistry}] ++
        for idx <- 0..(pool_size - 1) do
          name = port_name(idx)
          Supervisor.child_spec({Worker.PythonPort, [name: name]}, id: {:port, idx})
        end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Via-tuple for the port at index `idx`."
  def port_name(idx),
    do: {:via, Registry, {Worker.PortRegistry, {:port, idx}}}

  @doc "List of all port via-tuples."
  def port_names do
    pool_size = Application.get_env(:worker, :pool_size, 1)
    for idx <- 0..(pool_size - 1), do: port_name(idx)
  end
end
