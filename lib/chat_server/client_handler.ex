defmodule ChatServer.ClientHandler do
  @moduledoc """
  Handles a single TCP connection.
  Converts network events and process messages into a bidirectional interactive chat session.
  """
  require Logger
  alias ChatServer.RoomManager

  # ANSI color codes for rich terminal experience
  @c_reset "\e[0m"
  @c_bold "\e[1m"
  @c_cyan "\e[36m"
  @c_green "\e[32m"
  @c_yellow "\e[33m"
  @c_magenta "\e[35m"
  @c_red "\e[31m"
  @c_dim "\e[2m"

  @doc """
  Entrypoint for client connection task.
  """
  def start(socket) do
    # Handshake with RoomManager
    case RoomManager.register_user(self(), socket) do
      {:ok, nick, room} ->
        # Send banner
        send_line(socket, banner(nick, room))

        # Enable active socket mode now that we are ready to receive
        :ok = :inet.setopts(socket, active: true, packet: :line, mode: :binary)

        # Enter message loop
        loop(socket, nick, room)

      {:error, reason} ->
        send_line(socket, "Failed to connect: #{reason}")
        :gen_tcp.close(socket)
    end
  end

  defp loop(socket, nick, room) do
    receive do
      {:tcp, ^socket, raw_data} ->
        line = String.trim(raw_data)
        case handle_input(socket, line, nick, room) do
          {:continue, new_nick, new_room} ->
            loop(socket, new_nick, new_room)

          :quit ->
            send_line(socket, "#{@c_yellow}Goodbye!#{@c_reset}\r\n")
            RoomManager.leave(self())
            :gen_tcp.close(socket)
        end

      {:chat_message, msg_room, author, text} ->
        send_line(socket, "#{@c_cyan}[##{msg_room}]#{@c_reset} #{@c_bold}<#{author}>:#{@c_reset} #{text}")
        loop(socket, nick, room)

      {:direct_message, from_nick, text} ->
        send_line(socket, "#{@c_magenta}[PM from @#{from_nick}]:#{@c_reset} #{text}")
        loop(socket, nick, room)

      {:system_message, text} ->
        send_line(socket, "#{@c_dim}#{text}#{@c_reset}")
        loop(socket, nick, room)

      {:tcp_closed, ^socket} ->
        Logger.info("Client #{nick} closed TCP connection.")
        RoomManager.leave(self())
        :ok

      {:tcp_error, ^socket, reason} ->
        Logger.warning("Client #{nick} TCP error: #{inspect(reason)}")
        RoomManager.leave(self())
        :ok

      other ->
        Logger.debug("Unhandled message: #{inspect(other)}")
        loop(socket, nick, room)
    end
  end

  # Command handling

  defp handle_input(_socket, "", nick, room), do: {:continue, nick, room}

  defp handle_input(_socket, "/quit", _nick, _room) do
    :quit
  end

  defp handle_input(socket, "/help", nick, room) do
    send_line(socket, help_text())
    {:continue, nick, room}
  end

  defp handle_input(socket, "/rooms", nick, room) do
    case RoomManager.list_rooms() do
      {:ok, rooms} ->
        rows =
          rooms
          |> Enum.map(fn {r, count} ->
            prefix = if r == room, do: "#{@c_green}* ##{r}#{@c_reset}", else: "  ##{r}"
            "#{prefix} (#{count} #{if count == 1, do: "user", else: "users"})"
          end)
          |> Enum.join("\r\n")

        send_line(socket, "\r\n#{@c_bold}Available Rooms:#{@c_reset}\r\n#{rows}\r\n")

      {:error, reason} ->
        send_line(socket, "#{@c_red}Error: #{reason}#{@c_reset}")
    end

    {:continue, nick, room}
  end

  defp handle_input(socket, cmd, nick, room) when cmd in ["/users", "/who"] do
    case RoomManager.list_room_users(self()) do
      {:ok, current_room, users} ->
        send_line(socket, "\r\n#{@c_bold}Users in ##{current_room} (#{length(users)}):#{@c_reset}\r\n" <>
                          Enum.map_join(users, ", ", & &1) <> "\r\n")

      {:error, reason} ->
        send_line(socket, "#{@c_red}Error: #{reason}#{@c_reset}")
    end

    {:continue, nick, room}
  end

  defp handle_input(socket, "/nick " <> raw_nick, current_nick, room) do
    case RoomManager.set_nick(self(), raw_nick) do
      {:ok, new_nick} ->
        send_line(socket, "#{@c_green}Nickname changed to: #{new_nick}#{@c_reset}")
        {:continue, new_nick, room}

      {:error, reason} ->
        send_line(socket, "#{@c_red}#{reason}#{@c_reset}")
        {:continue, current_nick, room}
    end
  end

  defp handle_input(socket, "/join " <> raw_room, nick, current_room) do
    case RoomManager.join_room(self(), raw_room) do
      {:ok, new_room} ->
        send_line(socket, "#{@c_green}Joined room ##{new_room}#{@c_reset}")
        {:continue, nick, new_room}

      {:error, reason} ->
        send_line(socket, "#{@c_red}#{reason}#{@c_reset}")
        {:continue, nick, current_room}
    end
  end

  defp handle_input(socket, "/msg " <> rest, nick, room) do
    case String.split(rest, " ", parts: 2) do
      [target, message] when message != "" ->
        case RoomManager.direct_message(self(), target, message) do
          :ok ->
            send_line(socket, "#{@c_magenta}[PM to @#{target}]:#{@c_reset} #{message}")

          {:error, reason} ->
            send_line(socket, "#{@c_red}#{reason}#{@c_reset}")
        end

      _ ->
        send_line(socket, "#{@c_yellow}Usage: /msg <username> <message>#{@c_reset}")
    end

    {:continue, nick, room}
  end

  defp handle_input(socket, "/" <> unknown_cmd, nick, room) do
    cmd_name = unknown_cmd |> String.split(" ") |> List.first()
    send_line(socket, "#{@c_red}Unknown command: /#{cmd_name}. Type /help for available commands.#{@c_reset}")
    {:continue, nick, room}
  end

  # Default: Broadcast chat line to current room
  defp handle_input(socket, text, nick, room) do
    RoomManager.broadcast(self(), text)
    send_line(socket, "#{@c_cyan}[##{room}]#{@c_reset} #{@c_bold}<#{nick} (you)>:#{@c_reset} #{text}")
    {:continue, nick, room}
  end

  # Helpers

  defp send_line(socket, text) do
    :gen_tcp.send(socket, text <> "\r\n")
  end

  defp banner(nick, room) do
    """
    #{@c_cyan}=============================================================#{@c_reset}
    #{@c_bold}         Welcome to Elixir BEAM TCP Chat Server!            #{@c_reset}
    #{@c_cyan}=============================================================#{@c_reset}
    You are connected as: #{@c_bold}#{nick}#{@c_reset} in room #{@c_green}##{room}#{@c_reset}
    Type #{@c_yellow}/help#{@c_reset} to see all commands. Start chatting below!
    -------------------------------------------------------------
    """ |> String.trim_trailing()
  end

  defp help_text do
    """
    #{@c_bold}Available Commands:#{@c_reset}
      #{@c_yellow}/nick <name>#{@c_reset}         - Change your nickname (2-15 alphanumeric chars)
      #{@c_yellow}/join <room>#{@c_reset}         - Switch to a chat room (e.g. /join elixir)
      #{@c_yellow}/rooms#{@c_reset}               - List all active chat rooms
      #{@c_yellow}/users#{@c_reset}               - List users in your current room
      #{@c_yellow}/msg <user> <msg>#{@c_reset}    - Send a private direct message
      #{@c_yellow}/help#{@c_reset}                - Show this help menu
      #{@c_yellow}/quit#{@c_reset}                - Disconnect from server
    """ |> String.trim_trailing()
  end
end
