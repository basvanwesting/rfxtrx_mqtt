defmodule RfxtrxMqtt.Covers do
  @moduledoc """
  Position model for the covers, published over MQTT for Homebridge.

  Neither Forest nor Somfy RTS motors report back (the RFXtrx433XL only
  transmits to them), so position is emulated: a command starts travel, and
  after the device's `travel_ms` the cover is assumed to have arrived. A stop
  mid-travel leaves it at 50. Manual use of the original remotes is not seen.

  Topics (prefix configurable, default `rfxtrx`):

      <prefix>/<device>/set                  <- OPEN | CLOSE | STOP
      <prefix>/<device>/target_position/set  <- 0..100 (<= 50 closes, > 50 opens)
      <prefix>/<device>/target_position      -> 0 | 100, retained
      <prefix>/<device>/current_position     -> 0 | 50 | 100, retained
      <prefix>/<device>/position_state       -> INCREASING | DECREASING | STOPPED, retained
      <prefix>/status                        -> online | offline, retained

  Command topics and state topics never coincide: the retained state echo
  would otherwise come back as a command and loop.

  `status` is online only while the RFXtrx transmits, so a consumer never shows
  covers as reachable that cannot be moved. It is published from here alone,
  on every readiness change and whenever the MQTT connection comes up, and
  always from the RFXtrx's current answer rather than a value carried along.
  """

  use GenServer
  require Logger

  # Cover command => protocol command. `pair` registers the RFXtrx as an extra
  # remote in a motor that is in learn/programming mode.
  @protocol_commands %{
    blinds_t7: %{open: :open, close: :close, stop: :stop, pair: :confirm},
    rfy: %{open: :up, close: :down, stop: :stop, pair: :program}
  }

  defstruct devices: %{}, transmit: nil, ready?: nil, publish: nil, prefix: "rfxtrx"

  # -- API --------------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec command(GenServer.server(), String.t(), :open | :close | :stop) :: :ok | {:error, term()}
  def command(server \\ __MODULE__, device, cmd) when cmd in [:open, :close, :stop],
    do: GenServer.call(server, {:command, device, cmd})

  @spec set_target(GenServer.server(), String.t(), 0..100) :: :ok | {:error, term()}
  def set_target(server \\ __MODULE__, device, target) when target in 0..100,
    do: command(server, device, if(target > 50, do: :open, else: :close))

  @doc "Sends the pairing command for a device; the motor must be in learn mode."
  def pair(server \\ __MODULE__, device), do: GenServer.call(server, {:pair, device}, 20_000)

  @doc "Adopts a retained position from the broker when ours is still unknown."
  def hydrate(server \\ __MODULE__, device, position),
    do: GenServer.cast(server, {:hydrate, device, position})

  @doc "Publishes `<prefix>/status` from the RFXtrx's current readiness."
  def publish_availability(server \\ __MODULE__),
    do: GenServer.cast(server, :publish_availability)

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def parse_command("OPEN"), do: {:ok, :open}
  def parse_command("CLOSE"), do: {:ok, :close}
  def parse_command("STOP"), do: {:ok, :stop}
  def parse_command(other), do: {:error, {:unknown_command, other}}

  # -- Callbacks --------------------------------------------------------------

  @impl true
  def init(opts) do
    devices =
      Keyword.get_lazy(opts, :devices, fn ->
        RfxtrxMqtt.Devices.load!(Application.fetch_env!(:rfxtrx_mqtt, :devices_file))
      end)

    Logger.info("covers: #{devices |> Map.keys() |> Enum.sort() |> Enum.join(", ")}")

    state = %__MODULE__{
      devices:
        Map.new(devices, fn {name, device} ->
          {name, %{device: device, position: nil, state: :stopped, timer: nil}}
        end),
      prefix:
        Keyword.get_lazy(opts, :topic_prefix, fn ->
          Application.fetch_env!(:rfxtrx_mqtt, :topic_prefix)
        end),
      transmit: Keyword.get(opts, :transmit, &RfxtrxMqtt.Rfxtrx.send_command/4),
      ready?: Keyword.get(opts, :ready?, &RfxtrxMqtt.Rfxtrx.ready?/0),
      publish: Keyword.get(opts, :publish, &RfxtrxMqtt.Mqtt.publish/2)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     Map.new(state.devices, fn {name, d} -> {name, %{position: d.position, state: d.state}} end),
     state}
  end

  def handle_call({:pair, name}, _from, state) do
    case Map.fetch(state.devices, name) do
      :error -> {:reply, {:error, :unknown_device}, state}
      {:ok, d} -> {:reply, transmit(state, d.device, :pair), state}
    end
  end

  def handle_call({:command, name, cmd}, _from, state) do
    case Map.fetch(state.devices, name) do
      :error ->
        {:reply, {:error, :unknown_device}, state}

      {:ok, d} ->
        case transmit(state, d.device, cmd) do
          :ok ->
            Logger.info("covers: #{name} #{cmd}")
            {:reply, :ok, put_device(state, name, apply_command(d, name, cmd, state))}

          {:error, reason} = error ->
            Logger.warning("covers: #{name} #{cmd} failed: #{inspect(reason)}")
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_cast({:hydrate, name, position}, state) do
    case state.devices do
      %{^name => %{position: nil} = d} ->
        {:noreply, put_device(state, name, %{d | position: position})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast(:publish_availability, state) do
    payload = if state.ready?.(), do: "online", else: "offline"
    state.publish.("#{state.prefix}/status", payload)
    {:noreply, state}
  end

  @impl true
  def handle_info({:arrived, name, position}, state) do
    d = state.devices[name]
    publish(state, name, "current_position", position)
    publish(state, name, "position_state", "STOPPED")
    {:noreply, put_device(state, name, %{d | position: position, state: :stopped, timer: nil})}
  end

  # -- Internals --------------------------------------------------------------

  defp transmit(state, device, cmd) do
    protocol_cmd = @protocol_commands |> Map.fetch!(device.protocol) |> Map.fetch!(cmd)
    state.transmit.(device.protocol, device.id, device.unit, protocol_cmd)
  end

  defp apply_command(d, name, :stop, state) do
    cancel(d.timer)
    position = if d.state == :stopped, do: d.position, else: 50
    publish(state, name, "position_state", "STOPPED")
    if position, do: publish(state, name, "current_position", position)
    %{d | state: :stopped, position: position, timer: nil}
  end

  defp apply_command(d, name, cmd, state) do
    cancel(d.timer)

    {target, moving, motion} =
      if cmd == :open, do: {100, :opening, "INCREASING"}, else: {0, :closing, "DECREASING"}

    publish(state, name, "target_position", target)
    publish(state, name, "position_state", motion)
    timer = Process.send_after(self(), {:arrived, name, target}, d.device.travel_ms)
    %{d | state: moving, timer: timer}
  end

  defp put_device(state, name, d), do: %{state | devices: Map.put(state.devices, name, d)}

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp publish(state, name, key, value),
    do: state.publish.("#{state.prefix}/#{name}/#{key}", to_string(value))
end
