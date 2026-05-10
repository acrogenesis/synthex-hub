defmodule Worker.PortPool do
  @moduledoc """
  Checkout/checkin pool over the supervised Python ports.

  Used by the Broadway processors: each `handle_message/3` call
  borrows a port via `with_port/2`, scores its candidate, and the port
  is returned to the pool automatically.

  Crash semantics: when a borrower process dies (e.g. a Broadway
  processor crashes), its monitor fires here and the port is auto-
  returned to the pool. We don't re-borrow the same port on behalf of
  the deceased — the next checkout request is served instead.
  """
  use GenServer
  require Logger

  @default_checkout_timeout 60_000

  # ── Public API ──────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Borrow a port for the duration of `fun.(port_name)`. The port is
  returned to the pool whether `fun` returns normally or raises.
  """
  def with_port(timeout \\ @default_checkout_timeout, fun) when is_function(fun, 1) do
    {:ok, port} = checkout(timeout)

    try do
      fun.(port)
    after
      checkin(port)
    end
  end

  def checkout(timeout \\ @default_checkout_timeout),
    do: GenServer.call(__MODULE__, :checkout, timeout)

  def checkin(port), do: GenServer.cast(__MODULE__, {:checkin, port})

  def stats, do: GenServer.call(__MODULE__, :stats)

  # ── Implementation ──────────────────────────────────────────

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    available = Worker.PortSupervisor.port_names() |> :queue.from_list()

    state = %{
      available: available,
      waiting: :queue.new(),
      checked_out: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:checkout, {pid, _} = from, state) do
    case :queue.out(state.available) do
      {{:value, port}, rest} ->
        ref = Process.monitor(pid)
        checked_out = Map.put(state.checked_out, ref, {port, pid})
        {:reply, {:ok, port}, %{state | available: rest, checked_out: checked_out}}

      {:empty, _} ->
        {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      available: :queue.len(state.available),
      in_use: map_size(state.checked_out),
      waiting: :queue.len(state.waiting)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:checkin, port}, state) do
    state = clear_monitor_for(state, port)

    case :queue.out(state.waiting) do
      {{:value, {waiter_pid, _} = waiter}, rest_waiting} ->
        ref = Process.monitor(waiter_pid)
        checked_out = Map.put(state.checked_out, ref, {port, waiter_pid})
        GenServer.reply(waiter, {:ok, port})
        {:noreply, %{state | waiting: rest_waiting, checked_out: checked_out}}

      {:empty, _} ->
        {:noreply, %{state | available: :queue.in(port, state.available)}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.checked_out, ref) do
      {nil, _} ->
        {:noreply, state}

      {{port, _pid}, checked_out} ->
        if reason != :normal do
          Logger.warning("[PortPool] borrower DOWN (#{inspect(reason)}); returning #{inspect(port)}")
        end

        handle_cast({:checkin, port}, %{state | checked_out: checked_out})
    end
  end

  defp clear_monitor_for(state, port) do
    case Enum.find(state.checked_out, fn {_ref, {p, _}} -> p == port end) do
      {ref, _} ->
        Process.demonitor(ref, [:flush])
        %{state | checked_out: Map.delete(state.checked_out, ref)}

      nil ->
        state
    end
  end
end
