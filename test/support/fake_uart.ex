defmodule RfxtrxMqtt.FakeUART do
  @moduledoc """
  Stands in for Circuits.UART. Every write is forwarded to the owner as
  `{:uart_write, data}`; the test injects device output by sending
  `{:circuits_uart, "fake", data}` to the Rfxtrx server.
  """

  def start_link(opts),
    do: Agent.start_link(fn -> %{owner: Keyword.fetch!(opts, :owner), open: false} end)

  def open(pid, _name, _opts) do
    Agent.update(pid, &%{&1 | open: true})
    :ok
  end

  def write(pid, data) do
    send(Agent.get(pid, & &1.owner), {:uart_write, IO.iodata_to_binary(data)})
    :ok
  end

  def flush(pid, _dir \\ :both) do
    send(Agent.get(pid, & &1.owner), :uart_flush)
    :ok
  end

  def close(pid) do
    Agent.update(pid, &%{&1 | open: false})
    :ok
  end
end
