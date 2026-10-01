defmodule ChatServer.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:chat_server, :port, 4040)
    start_listener? = Application.get_env(:chat_server, :start_listener, true)

    base_children = [
      ChatServer.RoomManager,
      {Task.Supervisor, name: ChatServer.ClientSupervisor}
    ]

    children =
      if start_listener? do
        base_children ++ [{ChatServer.Listener, port: port}]
      else
        base_children
      end

    opts = [strategy: :one_for_one, name: ChatServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
