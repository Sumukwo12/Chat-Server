defmodule ChatServerTest do
  use ExUnit.Case, async: false
  alias ChatServer.RoomManager

  setup do
    RoomManager.reset()
    {:ok, port: 4040}
  end

  describe "RoomManager GenServer unit tests" do
    test "registers users and assigns unique guest nicknames" do
      dummy_socket = self()
      {:ok, nick1, "lobby"} = RoomManager.register_user(self(), dummy_socket)
      assert String.starts_with?(nick1, "guest")

      # Another process
      parent = self()
      spawn_link(fn ->
        {:ok, nick2, "lobby"} = RoomManager.register_user(self(), dummy_socket)
        send(parent, {:nick, nick2})
      end)

      assert_receive {:nick, nick2}, 1000
      assert nick1 != nick2
    end

    test "allows setting valid nickname and rejects duplicates or invalid names" do
      dummy_socket = self()
      {:ok, _nick, _room} = RoomManager.register_user(self(), dummy_socket)

      # Valid change
      assert {:ok, "alice"} = RoomManager.set_nick(self(), "alice")

      # Invalid characters / length
      assert {:error, _} = RoomManager.set_nick(self(), "x")
      assert {:error, _} = RoomManager.set_nick(self(), "too_long_name_exceeding_limit")
      assert {:error, _} = RoomManager.set_nick(self(), "bad nick!")

      # Another user trying to take 'alice'
      parent = self()
      spawn_link(fn ->
        {:ok, _nick, _room} = RoomManager.register_user(self(), dummy_socket)
        result = RoomManager.set_nick(self(), "ALICE")
        send(parent, {:result, result})
      end)

      assert_receive {:result, {:error, msg}}, 1000
      assert msg =~ "already taken"
    end

    test "switching rooms and listing users" do
      dummy_socket = self()
      {:ok, _nick, "lobby"} = RoomManager.register_user(self(), dummy_socket)
      {:ok, "alice"} = RoomManager.set_nick(self(), "alice")

      assert {:ok, "elixir"} = RoomManager.join_room(self(), "elixir")
      assert {:ok, "elixir", ["alice (you)"]} = RoomManager.list_room_users(self())

      {:ok, rooms} = RoomManager.list_rooms()
      assert {"elixir", 1} in rooms
    end

    test "direct messaging between users" do
      dummy_socket = self()
      parent = self()

      _pid_bob = spawn_link(fn ->
        {:ok, _nick, _room} = RoomManager.register_user(self(), dummy_socket)
        {:ok, "bob"} = RoomManager.set_nick(self(), "bob")
        send(parent, :bob_ready)

        receive do
          {:direct_message, from, text} ->
            send(parent, {:got_pm, from, text})
        after
          2000 -> send(parent, :pm_timeout)
        end
      end)

      assert_receive :bob_ready, 1000

      {:ok, _nick, _room} = RoomManager.register_user(self(), dummy_socket)
      {:ok, "alice"} = RoomManager.set_nick(self(), "alice")

      assert :ok = RoomManager.direct_message(self(), "bob", "Hello Bob secret!")
      assert_receive {:got_pm, "alice", "Hello Bob secret!"}, 1000
    end

    test "automatic cleanup on process death (OTP self-healing)" do
      dummy_socket = self()
      parent = self()

      pid = spawn(fn ->
        {:ok, _nick, _room} = RoomManager.register_user(self(), dummy_socket)
        {:ok, "charlie"} = RoomManager.set_nick(self(), "charlie")
        send(parent, :charlie_ready)

        receive do
          :crash -> exit(:simulated_crash)
        end
      end)

      assert_receive :charlie_ready, 1000

      # Charlie exists
      {:ok, _room, users_before} = RoomManager.list_room_users(pid)
      assert "charlie (you)" in users_before

      # Kill Charlie
      send(pid, :crash)
      Process.sleep(100)

      # Nick is freed and available again
      {:ok, _nick, _room} = RoomManager.register_user(self(), dummy_socket)
      assert {:ok, "charlie"} = RoomManager.set_nick(self(), "charlie")
    end
  end

  describe "Full TCP Network Integration Tests" do
    test "clients can connect over TCP, exchange messages and commands", %{port: port} do
      # 1. Connect Client 1 (Alice)
      {:ok, sock1} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])
      banner1 = drain_banner(sock1)
      assert banner1 =~ "Welcome to Elixir BEAM TCP Chat Server"

      # Alice sets nickname
      :gen_tcp.send(sock1, "/nick alice\r\n")
      line = recv_line(sock1)
      assert line =~ "Nickname changed to: alice"

      # 2. Connect Client 2 (Bob)
      {:ok, sock2} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])
      _banner2 = drain_banner(sock2)

      # Alice should receive system announcement that Bob joined
      system_msg = recv_line(sock1)
      assert system_msg =~ "joined the room"

      # Bob sets nickname
      :gen_tcp.send(sock2, "/nick bob\r\n")
      line_bob = recv_line(sock2)
      assert line_bob =~ "Nickname changed to: bob"

      # Alice sees Bob's nick change
      nick_announcement = recv_line(sock1)
      assert nick_announcement =~ "is now known as bob"

      # 3. Bob sends a chat message
      :gen_tcp.send(sock2, "Hello everyone in lobby!\r\n")
      _bob_echo = recv_line(sock2) # Bob's own confirmation

      # Alice receives the broadcast!
      alice_got = recv_line(sock1)
      assert alice_got =~ "[#lobby]"
      assert alice_got =~ "<bob>:"
      assert alice_got =~ "Hello everyone in lobby!"

      # 4. Private message from Alice to Bob
      :gen_tcp.send(sock1, "/msg bob Secret ping!\r\n")
      _alice_confirm = recv_line(sock1)

      bob_got_pm = recv_line(sock2)
      assert bob_got_pm =~ "[PM from @alice]:"
      assert bob_got_pm =~ "Secret ping!"

      # 5. Clean disconnect
      :gen_tcp.send(sock1, "/quit\r\n")
      quit_msg = recv_line(sock1)
      assert quit_msg =~ "Goodbye"

      # Bob receives departure notice
      depart_msg = recv_line(sock2)
      assert depart_msg =~ "alice disconnected"

      :gen_tcp.close(sock2)
    end
  end

  # Test Helpers

  defp recv_line(socket, timeout \\ 2000) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} -> line
      {:error, reason} -> flunk("Expected TCP line but got error: #{inspect(reason)}")
    end
  end

  defp drain_banner(socket, acc \\ "") do
    line = recv_line(socket)
    new_acc = acc <> line
    if String.contains?(line, "-------") do
      new_acc
    else
      drain_banner(socket, new_acc)
    end
  end
end
