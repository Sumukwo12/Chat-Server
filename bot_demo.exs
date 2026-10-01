# Bot Simulation Demo for ChatServer
# Spawns 3 automated clients (Alice, Bob, Charlie) interacting over TCP on port 4040.

defmodule BotDemo do
  @port 4040

  def run do
    IO.puts("\n========================================================")
    IO.puts("    STARTING MULTI-USER TCP CHAT SERVER BOT DEMO        ")
    IO.puts("========================================================\n")

    # Start Alice
    alice = spawn_bot("Alice", [
      {:wait, 300},
      {:send, "/nick alice"},
      {:wait, 500},
      {:send, "Hi everyone, I just joined #lobby!"},
      {:wait, 1500},
      {:send, "/msg bob Hey Bob, glad you could make it!"},
      {:wait, 2000},
      {:send, "/join elixir"},
      {:wait, 500},
      {:send, "Welcome to #elixir room!"},
      {:wait, 2000},
      {:send, "/rooms"},
      {:wait, 1000},
      {:send, "/quit"}
    ])

    # Start Bob
    bob = spawn_bot("Bob", [
      {:wait, 800},
      {:send, "/nick bob"},
      {:wait, 700},
      {:send, "Hey Alice! Checking out this BEAM server."},
      {:wait, 2500},
      {:send, "/join elixir"},
      {:wait, 1000},
      {:send, "Elixir processes make this so fast!"},
      {:wait, 2000},
      {:send, "/quit"}
    ])

    # Start Charlie
    charlie = spawn_bot("Charlie", [
      {:wait, 1400},
      {:send, "/nick charlie"},
      {:wait, 600},
      {:send, "/users"},
      {:wait, 1200},
      {:send, "Who is in #elixir? Let me check /rooms"},
      {:wait, 500},
      {:send, "/rooms"},
      {:wait, 3500},
      {:send, "/quit"}
    ])

    # Monitor bots until they finish
    refs = [Process.monitor(alice), Process.monitor(bob), Process.monitor(charlie)]
    wait_for_all(refs)

    IO.puts("\n========================================================")
    IO.puts("            BOT DEMO COMPLETED SUCCESSFULLY!            ")
    IO.puts("========================================================\n")
  end

  defp spawn_bot(name, script) do
    spawn(fn ->
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: :line, active: true])

      # Background receiver to print incoming TCP messages
      receiver =
        spawn_link(fn ->
          bot_receiver_loop(name, socket)
        end)

      # Execute script actions
      for action <- script do
        case action do
          {:wait, ms} ->
            Process.sleep(ms)

          {:send, text} ->
            IO.puts("[INPUT > #{name}] #{text}")
            :gen_tcp.send(socket, text <> "\r\n")
        end
      end

      Process.sleep(500)
      Process.unlink(receiver)
      Process.exit(receiver, :normal)
      :gen_tcp.close(socket)
    end)
  end

  defp bot_receiver_loop(bot_name, socket) do
    receive do
      {:tcp, ^socket, line} ->
        clean = String.trim_trailing(line)
        IO.puts("  [#{bot_name} heard] #{clean}")
        bot_receiver_loop(bot_name, socket)

      {:tcp_closed, ^socket} ->
        :ok

      _other ->
        bot_receiver_loop(bot_name, socket)
    end
  end

  defp wait_for_all([]), do: :ok
  defp wait_for_all(refs) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} ->
        wait_for_all(List.delete(refs, ref))
    end
  end
end

BotDemo.run()
