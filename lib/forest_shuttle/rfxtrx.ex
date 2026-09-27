defmodule ForestShuttle.Rfxtrx do
  @moduledoc """
  Owns the serial port to the RFXtrx433XL.

  On (re)connect: reset, wait, flush, request status. Commands are serialised;
  each one waits for the transmitter ACK carrying its sequence number.
  The port may be absent or vanish (USB replug); the server keeps retrying
  instead of crashing, and pending callers get `{:error, :disconnected}`.
  """

  use GenServer
  require Logger
  alias ForestShuttle.Rfxtrx.Packet

  @reset_delay_ms 300
  @ack_timeout_ms 5_000
  @reconnect_ms 5_000

  defstruct uart: nil,
            uart_mod: Circuits.UART,
            uart_pid: nil,
            port: nil,
            device: nil,
            buffer: <<>>,
            seq: 0,
            status: nil,
            pending: nil,
            queue: :queue.new(),
            reset_delay_ms: @reset_delay_ms,
            ack_timeout_ms: @ack_timeout_ms,
            reconnect_ms: @reconnect_ms

  # -- API --------------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Sends a Blinds1 T7 command and waits for the ACK."
  @spec send_command(GenServer.server(), non_neg_integer(), 0..15, Packet.command()) ::
          :ok | {:error, term()}
  def send_command(server \\ __MODULE__, id, unit, command) do
    GenServer.call(server, {:send, id, unit, command}, 15_000)
  end

  @doc "Interface status as reported after connect, or nil when not connected."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # -- Callbacks --------------------------------------------------------------

  @impl true
  def init(opts) do
    {uart_mod, uart_opts} = Keyword.get(opts, :uart, {Circuits.UART, []})
    {:ok, uart_pid} = uart_mod.start_link(uart_opts)

    state = %__MODULE__{
      uart_mod: uart_mod,
      uart_pid: uart_pid,
      port: Keyword.get(opts, :port, Application.fetch_env!(:forest_shuttle, :rfxtrx_port)),
      reset_delay_ms: Keyword.get(opts, :reset_delay_ms, @reset_delay_ms),
      ack_timeout_ms: Keyword.get(opts, :ack_timeout_ms, @ack_timeout_ms),
      reconnect_ms: Keyword.get(opts, :reconnect_ms, @reconnect_ms)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    with {:ok, device} <- resolve_device(state.port),
         :ok <- state.uart_mod.open(state.uart_pid, device, speed: 38_400, active: true) do
      Logger.info("rfxtrx: opened #{device}, resetting")
      :ok = state.uart_mod.write(state.uart_pid, Packet.reset())
      Process.send_after(self(), :request_status, state.reset_delay_ms)
      {:noreply, %{state | device: device, buffer: <<>>, status: nil}}
    else
      {:error, reason} ->
        Logger.warning("rfxtrx: cannot open #{state.port}: #{inspect(reason)}, retrying")
        Process.send_after(self(), :connect, state.reconnect_ms)
        {:noreply, %{state | device: nil, status: nil}}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:send, _, _, _}, _from, %{device: nil} = state),
    do: {:reply, {:error, :disconnected}, state}

  def handle_call({:send, id, unit, command}, from, state) do
    state = %{state | queue: :queue.in({from, id, unit, command}, state.queue)}
    {:noreply, maybe_transmit(state)}
  end

  @impl true
  def handle_info(:connect, state), do: {:noreply, state, {:continue, :connect}}

  def handle_info(:request_status, %{device: nil} = state), do: {:noreply, state}

  def handle_info(:request_status, state) do
    :ok = state.uart_mod.flush(state.uart_pid)
    state = %{state | buffer: <<>>, seq: Packet.next_seq(state.seq)}
    :ok = state.uart_mod.write(state.uart_pid, Packet.status_request(state.seq))
    {:noreply, state}
  end

  def handle_info({:circuits_uart, _dev, {:error, reason}}, state) do
    Logger.warning("rfxtrx: port error #{inspect(reason)}, reconnecting")
    {:noreply, disconnect(state)}
  end

  def handle_info({:circuits_uart, _dev, data}, state) when is_binary(data) do
    {frames, rest} = Packet.split(state.buffer <> data)
    state = Enum.reduce(frames, %{state | buffer: rest}, &handle_frame(Packet.decode(&1), &2))
    {:noreply, state}
  end

  def handle_info({:ack_timeout, seq}, %{pending: {from, seq, _}} = state) do
    Logger.warning("rfxtrx: no ACK for seq #{seq}")
    GenServer.reply(from, {:error, :timeout})
    {:noreply, maybe_transmit(%{state | pending: nil})}
  end

  def handle_info({:ack_timeout, _stale}, state), do: {:noreply, state}

  # -- Internals --------------------------------------------------------------

  defp handle_frame({:status, _seq, status}, state) do
    Logger.info("rfxtrx: ready, transceiver #{status.transceiver_type} fw #{status.firmware}")
    maybe_transmit(%{state | status: status})
  end

  defp handle_frame({:ack, seq, code}, %{pending: {from, seq, timer}} = state) do
    Process.cancel_timer(timer)
    GenServer.reply(from, ack_result(code))
    maybe_transmit(%{state | pending: nil})
  end

  defp handle_frame(other, state) do
    Logger.debug("rfxtrx: ignoring frame #{inspect(other)}")
    state
  end

  defp ack_result(:ok), do: :ok
  defp ack_result(:ok_delayed), do: :ok
  defp ack_result(other), do: {:error, other}

  # Transmit the next queued command when the device is ready and nothing is in flight.
  defp maybe_transmit(%{pending: nil, status: status, device: device} = state)
       when status != nil and device != nil do
    case :queue.out(state.queue) do
      {{:value, {from, id, unit, command}}, queue} ->
        seq = Packet.next_seq(state.seq)
        :ok = state.uart_mod.write(state.uart_pid, Packet.blinds1(id, unit, command, seq))
        timer = Process.send_after(self(), {:ack_timeout, seq}, state.ack_timeout_ms)
        %{state | queue: queue, seq: seq, pending: {from, seq, timer}}

      {:empty, _} ->
        state
    end
  end

  defp maybe_transmit(state), do: state

  defp disconnect(state) do
    state.uart_mod.close(state.uart_pid)

    if state.pending, do: GenServer.reply(elem(state.pending, 0), {:error, :disconnected})

    for {from, _, _, _} <- :queue.to_list(state.queue),
        do: GenServer.reply(from, {:error, :disconnected})

    Process.send_after(self(), :connect, state.reconnect_ms)
    %{state | device: nil, status: nil, pending: nil, queue: :queue.new(), buffer: <<>>}
  end

  # Accepts a glob, a symlink (e.g. /dev/serial/by-id/...) or a device name;
  # returns the name Circuits.UART expects ("ttyUSB0").
  defp resolve_device(port) do
    case Path.wildcard(port) do
      [] -> if File.exists?(port), do: {:ok, device_name(port)}, else: {:error, :enoent}
      [path | _] -> {:ok, device_name(path)}
    end
  end

  defp device_name(path) do
    path =
      case File.read_link(path) do
        {:ok, target} -> Path.expand(target, Path.dirname(path))
        _ -> path
      end

    Path.basename(path)
  end
end
