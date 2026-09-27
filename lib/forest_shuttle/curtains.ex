defmodule ForestShuttle.Curtains do
  @moduledoc """
  Position model for the curtains, published over MQTT for Homebridge.

  Forest motors do not report back (the RFXtrx433XL only transmits to them),
  so position is emulated: a command starts travel, and after `travel_ms` the
  curtain is assumed to have arrived. A stop mid-travel leaves it at 50.

  Topics (prefix configurable, default `forest_shuttle`):

      <prefix>/<room>/set              <- OPEN | CLOSE | STOP
      <prefix>/<room>/target_position  <- 0..100 (<= 50 closes, > 50 opens)
      <prefix>/<room>/current_position -> 0 | 50 | 100, retained
      <prefix>/<room>/position_state   -> INCREASING | DECREASING | STOPPED, retained
  """

  use GenServer
  require Logger

  defstruct rooms: %{}, travel_ms: 20_000, transmit: nil, publish: nil, prefix: "forest_shuttle"

  # -- API --------------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec command(GenServer.server(), String.t(), :open | :close | :stop) :: :ok | {:error, term()}
  def command(server \\ __MODULE__, room, cmd) when cmd in [:open, :close, :stop],
    do: GenServer.call(server, {:command, room, cmd})

  @spec set_target(GenServer.server(), String.t(), 0..100) :: :ok | {:error, term()}
  def set_target(server \\ __MODULE__, room, target) when target in 0..100,
    do: command(server, room, if(target > 50, do: :open, else: :close))

  @doc "Adopts a retained position from the broker when ours is still unknown."
  def hydrate(server \\ __MODULE__, room, position),
    do: GenServer.cast(server, {:hydrate, room, position})

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def parse_command("OPEN"), do: {:ok, :open}
  def parse_command("CLOSE"), do: {:ok, :close}
  def parse_command("STOP"), do: {:ok, :stop}
  def parse_command(other), do: {:error, {:unknown_command, other}}

  # -- Callbacks --------------------------------------------------------------

  @impl true
  def init(opts) do
    env = fn key ->
      Keyword.get_lazy(opts, key, fn -> Application.fetch_env!(:forest_shuttle, key) end)
    end

    rooms =
      Map.new(env.(:rooms), fn {room, device} ->
        {room, %{device: device, position: nil, state: :stopped, timer: nil}}
      end)

    state = %__MODULE__{
      rooms: rooms,
      travel_ms: env.(:travel_ms),
      prefix: env.(:topic_prefix),
      transmit: Keyword.get(opts, :transmit, &ForestShuttle.Rfxtrx.send_command/3),
      publish: Keyword.get(opts, :publish, &ForestShuttle.Mqtt.publish/2)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     Map.new(state.rooms, fn {room, r} -> {room, %{position: r.position, state: r.state}} end),
     state}
  end

  def handle_call({:command, room, cmd}, _from, state) do
    case Map.fetch(state.rooms, room) do
      :error ->
        {:reply, {:error, :unknown_room}, state}

      {:ok, %{device: %{id: id, unit: unit}} = r} ->
        case state.transmit.(id, unit, cmd) do
          :ok ->
            {:reply, :ok, put_room(state, room, apply_command(r, room, cmd, state))}

          {:error, reason} = error ->
            Logger.warning("curtains: #{room} #{cmd} failed: #{inspect(reason)}")
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_cast({:hydrate, room, position}, state) do
    case state.rooms do
      %{^room => %{position: nil} = r} ->
        {:noreply, put_room(state, room, %{r | position: position})}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:arrived, room, position}, state) do
    r = state.rooms[room]
    publish(state, room, "current_position", position)
    publish(state, room, "position_state", "STOPPED")
    {:noreply, put_room(state, room, %{r | position: position, state: :stopped, timer: nil})}
  end

  # -- Internals --------------------------------------------------------------

  defp apply_command(r, room, :stop, state) do
    cancel(r.timer)
    position = if r.state == :stopped, do: r.position, else: 50
    publish(state, room, "position_state", "STOPPED")
    if position, do: publish(state, room, "current_position", position)
    %{r | state: :stopped, position: position, timer: nil}
  end

  defp apply_command(r, room, cmd, state) do
    cancel(r.timer)

    {target, moving, motion} =
      if cmd == :open, do: {100, :opening, "INCREASING"}, else: {0, :closing, "DECREASING"}

    publish(state, room, "target_position", target)
    publish(state, room, "position_state", motion)
    timer = Process.send_after(self(), {:arrived, room, target}, state.travel_ms)
    %{r | state: moving, timer: timer}
  end

  defp put_room(state, room, r), do: %{state | rooms: Map.put(state.rooms, room, r)}

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp publish(state, room, key, value),
    do: state.publish.("#{state.prefix}/#{room}/#{key}", to_string(value))
end
