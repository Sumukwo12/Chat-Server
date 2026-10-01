# Interactive Terminal Chat Client
# Usage:
#   elixir client.exs [host] [port]

defmodule Client do
  def start([host_str, port_str]) do
    connect(String.to_charlist(host_str), String.to_integer(port_str))
  end

  def start([host_str]) do
    connect(String.to_charlist(host_str), 4040)
  end

  def start([]) do
    connect(~c"127.0.0.1", 4040)
  end

  defp connect(host, port) do
    IO.puts("Connecting to #{host}:#{port}...")

    case :gen_tcp.connect(host, port, [:binary, packet: :line, active: true]) do
      {:ok, socket} ->
        # Background receiver task
        recv_pid = spawn_link(fn -> receive_loop(socket) end)
        :ok = :gen_tcp.controlling_process(socket, recv_pid)
        # Foreground sender loop
        send_loop(socket)

      {:error, reason} ->
        IO.puts("Failed to connect: #{inspect(reason)}")
    end
  end

  defp receive_loop(socket) do
    receive do
      {:tcp, ^socket, data} ->
        IO.write(data)
        receive_loop(socket)

      {:tcp_closed, ^socket} ->
        IO.puts("\nConnection closed by server.")
        System.halt(0)

      {:tcp_error, ^socket, reason} ->
        IO.puts("\nConnection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp send_loop(socket) do
    case IO.gets("") do
      :eof ->
        :gen_tcp.close(socket)
        System.halt(0)

      {:error, reason} ->
        IO.puts("Input error: #{inspect(reason)}")
        System.halt(1)

      line ->
        :gen_tcp.send(socket, String.trim_trailing(line, "\r\n") <> "\r\n")
        send_loop(socket)
    end
  end
end

Client.start(System.argv())
