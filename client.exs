# Interactive Terminal Chat Client
#
# Usage:
#   elixir client.exs [host] [port]
#   elixir client.exs --help
#
# Defaults to 127.0.0.1:4040.

defmodule Client do
  @default_host "127.0.0.1"
  @default_port 4040
  @connect_timeout 5_000

  def main(argv) do
    case parse_args(argv) do
      {:ok, host, port} ->
        connect(host, port)

      :help ->
        IO.puts(usage())
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, "Error: #{message}\n\n#{usage()}")
        System.halt(2)
    end
  end

  # Argument parsing

  defp parse_args(argv) do
    if Enum.any?(argv, &(&1 in ["-h", "--help"])) do
      :help
    else
      case argv do
        [] -> {:ok, @default_host, @default_port}
        [host] -> {:ok, host, @default_port}
        [host, port] -> with {:ok, port} <- parse_port(port), do: {:ok, host, port}
        _ -> {:error, "too many arguments"}
      end
    end
  end

  defp parse_port(str) do
    case Integer.parse(str) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> {:error, "invalid port #{inspect(str)} (expected a number from 1 to 65535)"}
    end
  end

  defp usage do
    """
    Usage: elixir client.exs [host] [port]

      host   Server hostname or IP (default: #{@default_host})
      port   Server TCP port       (default: #{@default_port})

    Type /help once connected to see chat commands. Press Ctrl+D (Ctrl+Z then
    Enter on Windows) or type /quit to disconnect.
    """
    |> String.trim_trailing()
  end

  # Connection

  defp connect(host, port) do
    IO.puts("Connecting to #{host}:#{port}...")

    # Start passive so no data is delivered before the receiver owns the socket.
    opts = [:binary, packet: :line, active: false]

    case :gen_tcp.connect(String.to_charlist(host), port, opts, @connect_timeout) do
      {:ok, socket} ->
        start_receiver(socket)
        send_loop(socket)

      {:error, reason} ->
        IO.puts(:stderr, "Failed to connect to #{host}:#{port}: #{describe_error(reason)}")
        System.halt(1)
    end
  end

  defp start_receiver(socket) do
    receiver =
      spawn_link(fn ->
        receive do
          :socket_ready -> :ok
        end

        :ok = :inet.setopts(socket, active: true)
        receive_loop(socket)
      end)

    :ok = :gen_tcp.controlling_process(socket, receiver)
    send(receiver, :socket_ready)
  end

  defp describe_error(:econnrefused), do: "connection refused (is the server running?)"
  defp describe_error(:timeout), do: "timed out after #{div(@connect_timeout, 1000)}s"
  defp describe_error(:nxdomain), do: "unknown host"
  defp describe_error(:ehostunreach), do: "host unreachable"
  defp describe_error(reason), do: inspect(reason)

  # Server -> terminal

  defp receive_loop(socket) do
    receive do
      {:tcp, ^socket, data} ->
        IO.write(data)
        receive_loop(socket)

      {:tcp_closed, ^socket} ->
        IO.puts("\nConnection closed by server.")
        System.halt(0)

      {:tcp_error, ^socket, reason} ->
        IO.puts(:stderr, "\nConnection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Terminal -> server

  defp send_loop(socket) do
    case IO.gets("") do
      :eof ->
        :gen_tcp.close(socket)
        IO.puts("Disconnected.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "Input error: #{inspect(reason)}")
        System.halt(1)

      line ->
        text = line |> String.trim_trailing("\n") |> String.trim_trailing("\r")

        case :gen_tcp.send(socket, text <> "\r\n") do
          :ok ->
            send_loop(socket)

          {:error, reason} ->
            IO.puts(:stderr, "\nFailed to send message: #{describe_error(reason)}")
            System.halt(1)
        end
    end
  end
end

Client.main(System.argv())
