defmodule ChatServer.RoomManager do
  @moduledoc """
  Manages chat rooms, active users, nicknames, and message routing.
  Monitors client handler processes to ensure automatic cleanup on disconnect/crash.
  """
  use GenServer
  require Logger

  @default_room "lobby"

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Registers a new connected client process and assigns an initial nickname."
  def register_user(server \\ __MODULE__, pid, socket) do
    GenServer.call(server, {:register_user, pid, socket})
  end

  @doc "Changes the user's nickname."
  def set_nick(server \\ __MODULE__, pid, new_nick) do
    GenServer.call(server, {:set_nick, pid, new_nick})
  end

  @doc "Switches user to a different room."
  def join_room(server \\ __MODULE__, pid, room_name) do
    GenServer.call(server, {:join_room, pid, room_name})
  end

  @doc "Broadcasts a chat message to everyone in the sender's current room."
  def broadcast(server \\ __MODULE__, pid, message) do
    GenServer.cast(server, {:broadcast, pid, message})
  end

  @doc "Sends a private direct message to a specific user."
  def direct_message(server \\ __MODULE__, pid, target_nick, message) do
    GenServer.call(server, {:direct_message, pid, target_nick, message})
  end

  @doc "Lists all users currently in the sender's room."
  def list_room_users(server \\ __MODULE__, pid) do
    GenServer.call(server, {:list_room_users, pid})
  end

  @doc "Lists all active rooms and their current user counts."
  def list_rooms(server \\ __MODULE__) do
    GenServer.call(server, :list_rooms)
  end

  @doc "Explicitly disconnects/leaves a user."
  def leave(server \\ __MODULE__, pid) do
    GenServer.cast(server, {:leave, pid})
  end

  @doc "Resets all state (useful for tests)."
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  defp initial_state do
    %{
      users: %{},        # pid => %{nick: String.t(), socket: port(), room: String.t(), monitor_ref: reference()}
      nicks: %{},        # lowercase_nick => pid
      rooms: %{},        # room_name => MapSet.new([pid])
      guest_counter: 1
    }
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # Demonitor all active processes
    for {_pid, user} <- state.users do
      Process.demonitor(user.monitor_ref, [:flush])
    end
    {:reply, :ok, initial_state()}
  end

  @impl true
  def handle_call({:register_user, pid, socket}, _from, state) do
    nick = "guest#{state.guest_counter}"
    ref = Process.monitor(pid)

    user = %{
      nick: nick,
      socket: socket,
      room: @default_room,
      monitor_ref: ref
    }

    new_users = Map.put(state.users, pid, user)
    new_nicks = Map.put(state.nicks, String.downcase(nick), pid)
    room_members = Map.get(state.rooms, @default_room, MapSet.new()) |> MapSet.put(pid)
    new_rooms = Map.put(state.rooms, @default_room, room_members)

    # Announce to room members
    broadcast_system(new_rooms, new_users, @default_room, "* #{nick} joined the room.", pid)

    new_state = %{state |
      users: new_users,
      nicks: new_nicks,
      rooms: new_rooms,
      guest_counter: state.guest_counter + 1
    }

    {:reply, {:ok, nick, @default_room}, new_state}
  end

  @impl true
  def handle_call({:set_nick, pid, raw_nick}, _from, state) do
    nick = String.trim(raw_nick)
    lower = String.downcase(nick)

    cond do
      not Regex.match?(~r/^[a-zA-Z0-9_-]{2,15}$/, nick) ->
        {:reply, {:error, "Nickname must be 2-15 characters (alphanumeric, _, -)."}, state}

      Map.has_key?(state.nicks, lower) and Map.get(state.nicks, lower) != pid ->
        {:reply, {:error, "Nickname '#{nick}' is already taken."}, state}

      true ->
        case Map.get(state.users, pid) do
          nil ->
            {:reply, {:error, "User not found."}, state}

          user ->
            old_nick = user.nick
            old_lower = String.downcase(old_nick)

            new_nicks = state.nicks |> Map.delete(old_lower) |> Map.put(lower, pid)
            new_users = Map.put(state.users, pid, %{user | nick: nick})

            broadcast_system(state.rooms, new_users, user.room, "* #{old_nick} is now known as #{nick}.", pid)

            {:reply, {:ok, nick}, %{state | users: new_users, nicks: new_nicks}}
        end
    end
  end

  @impl true
  def handle_call({:join_room, pid, raw_room}, _from, state) do
    room = String.trim(raw_room) |> String.downcase()

    cond do
      not Regex.match?(~r/^[a-zA-Z0-9_-]{1,20}$/, room) ->
        {:reply, {:error, "Room name must be 1-20 characters (alphanumeric, _, -)."}, state}

      true ->
        case Map.get(state.users, pid) do
          nil ->
            {:reply, {:error, "User not found."}, state}

          %{room: ^room} ->
            {:reply, {:error, "You are already in ##{room}."}, state}

          user ->
            old_room = user.room
            # Leave old room
            old_members = Map.get(state.rooms, old_room, MapSet.new()) |> MapSet.delete(pid)
            broadcast_system(state.rooms, state.users, old_room, "* #{user.nick} left ##{old_room}.", pid)

            # Join new room
            new_members = Map.get(state.rooms, room, MapSet.new()) |> MapSet.put(pid)
            new_rooms = state.rooms
                        |> cleanup_empty_room(old_room, old_members)
                        |> Map.put(room, new_members)

            new_users = Map.put(state.users, pid, %{user | room: room})

            broadcast_system(new_rooms, new_users, room, "* #{user.nick} joined ##{room}.", pid)

            {:reply, {:ok, room}, %{state | users: new_users, rooms: new_rooms}}
        end
    end
  end

  @impl true
  def handle_call({:direct_message, pid, target_nick, message}, _from, state) do
    sender = Map.get(state.users, pid)
    target_lower = String.downcase(String.trim(target_nick))

    case Map.get(state.nicks, target_lower) do
      nil ->
        {:reply, {:error, "User '#{target_nick}' is not online."}, state}

      target_pid when target_pid == pid ->
        {:reply, {:error, "You cannot send a private message to yourself."}, state}

      target_pid ->
        send(target_pid, {:direct_message, sender.nick, message})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:list_room_users, pid}, _from, state) do
    case Map.get(state.users, pid) do
      nil ->
        {:reply, {:error, "User not found."}, state}

      user ->
        members = Map.get(state.rooms, user.room, MapSet.new())
        user_list =
          members
          |> Enum.map(fn p ->
            u = Map.get(state.users, p)
            if p == pid, do: "#{u.nick} (you)", else: u.nick
          end)
          |> Enum.sort()

        {:reply, {:ok, user.room, user_list}, state}
    end
  end

  @impl true
  def handle_call(:list_rooms, _from, state) do
    rooms_summary =
      state.rooms
      |> Enum.map(fn {room, members} -> {room, MapSet.size(members)} end)
      |> Enum.sort_by(fn {_r, count} -> -count end)

    {:reply, {:ok, rooms_summary}, state}
  end

  @impl true
  def handle_cast({:broadcast, pid, message}, state) do
    case Map.get(state.users, pid) do
      nil ->
        {:noreply, state}

      user ->
        members = Map.get(state.rooms, user.room, MapSet.new())
        payload = {:chat_message, user.room, user.nick, message}

        for member_pid <- members, member_pid != pid do
          send(member_pid, payload)
        end

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:leave, pid}, state) do
    {:noreply, remove_user(pid, state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    Logger.info("Client process #{inspect(pid)} disconnected/crashed, cleaning up.")
    {:noreply, remove_user(pid, state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Helper Functions

  defp remove_user(pid, state) do
    case Map.pop(state.users, pid) do
      {nil, _} ->
        state

      {user, new_users} ->
        Process.demonitor(user.monitor_ref, [:flush])
        new_nicks = Map.delete(state.nicks, String.downcase(user.nick))

        old_members = Map.get(state.rooms, user.room, MapSet.new()) |> MapSet.delete(pid)
        broadcast_system(state.rooms, state.users, user.room, "* #{user.nick} disconnected.", pid)

        new_rooms = cleanup_empty_room(state.rooms, user.room, old_members)

        %{state | users: new_users, nicks: new_nicks, rooms: new_rooms}
    end
  end

  defp broadcast_system(rooms, _users, room, text, exclude_pid) do
    members = Map.get(rooms, room, MapSet.new())
    payload = {:system_message, text}

    for member_pid <- members, member_pid != exclude_pid do
      send(member_pid, payload)
    end
  end

  defp cleanup_empty_room(rooms, room, members) do
    if MapSet.size(members) == 0 and room != @default_room do
      Map.delete(rooms, room)
    else
      Map.put(rooms, room, members)
    end
  end
end
