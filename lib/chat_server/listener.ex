defmodule ChatServer.Listener do
  @moduledoc """
  TCP Listener process that accepts incoming client connections
  and delegates them to supervised ClientHandler tasks.
  """
  use GenServer
  require Logger
  alias ChatServer.ClientHandler

  @default_port 4040

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, Application.get_env(:chat_server, :port, @default_port))

    # Listen options:
    # - :binary: data received as binary binaries
    # - packet: :line: splits input automatically by \r\n or \n
    # - active: false: start in passive mode so accept is clean
    # - reuseaddr: true: allows rapid restart on same port
    tcp_options = [:binary, packet: :line, active: false, reuseaddr: true]

    case :gen_tcp.listen(port, tcp_options) do
      {:ok, listen_socket} ->
        Logger.info("ChatServer TCP Listener started on port #{port}.")
        {:ok, %{listen_socket: listen_socket, port: port}, {:continue, :accept}}

      {:error, reason} ->
        Logger.error("Failed to bind TCP port #{port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:accept, state) do
    # Spawn the accept loop in a dedicated background task to keep GenServer responsive
    Task.start_link(fn -> accept_loop(state.listen_socket) end)
    {:noreply, state}
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        # Spawn supervised client handler
        {:ok, pid} =
          Task.Supervisor.start_child(ChatServer.ClientSupervisor, fn ->
            receive do
              :go -> ClientHandler.start(client_socket)
            after
              5000 -> :gen_tcp.close(client_socket)
            end
          end)

        # Hand over socket ownership to the client process
        :ok = :gen_tcp.controlling_process(client_socket, pid)
        send(pid, :go)

        # Loop immediately for next connection
        accept_loop(listen_socket)

      {:error, :closed} ->
        Logger.info("TCP listen socket closed.")
        :ok

      {:error, reason} ->
        Logger.error("TCP accept error: #{inspect(reason)}")
        # Brief backoff to prevent tight loop on transient network errors
        Process.sleep(100)
        accept_loop(listen_socket)
    end
  end
end
