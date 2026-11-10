# Multi-User TCP Chat Server in Elixir

A concurrent, fault-tolerant, multi-room TCP chat server built with **Elixir** and **OTP** running on the Erlang BEAM virtual machine.

---

## Prerequisites

- Elixir **1.20** or later (tested with 1.20.4)
- Erlang/OTP **29** (required by Elixir 1.20)
- A terminal that supports ANSI colors (most modern terminals do)

## Architecture & OTP Supervision Tree

The application leverages the BEAM's actor model where every connected TCP client is isolated into its own lightweight process (~2 KB):

```
                        ChatServer.Supervisor (one_for_one)
                                  │
          ┌───────────────────────┼────────────────────────┐
          │                       │                        │
ChatServer.RoomManager   ChatServer.ClientSupervisor    ChatServer.Listener
      (GenServer)             (Task.Supervisor)             (GenServer)
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
          ChatServer.ClientHandler    ChatServer.ClientHandler ...
             (Socket process)            (Socket process)
```

### Core Components:

1. **[`ChatServer.Listener`](lib/chat_server/listener.ex)**:
   - Listens on TCP port `4040` using `:gen_tcp` with `packet: :line` and `active: false`.
   - On incoming connection, delegates the socket to a supervised Task under `Task.Supervisor`.
   - Transfers socket ownership using `:gen_tcp.controlling_process/2`.

2. **[`ChatServer.ClientHandler`](lib/chat_server/client_handler.ex)**:
   - Sets the socket to **active mode** (`:inet.setopts(socket, active: true)`).
   - In active mode, incoming network bytes are sent directly to the process mailbox as `{:tcp, socket, line}`.
   - Manages interactive command parsing, ANSI color formatting, and delivers messages to the client socket.

3. **[`ChatServer.RoomManager`](lib/chat_server/room_manager.ex)**:
   - A centralized `GenServer` tracking online users, nickname uniqueness, and room memberships (default room: `#lobby`).
   - Monitors each client handler process using `Process.monitor/1`.
   - **"Let It Crash" / Self-Healing**: If any client process terminates or crashes unexpectedly, the `handle_info({:DOWN, ...})` callback automatically reclaims the nickname, removes the user from the room, and broadcasts a departure notice to the remaining members.

---

## Features & Supported Commands

| Command | Description | Example |
| :--- | :--- | :--- |
| **`/nick <name>`** | Set or change nickname (2-15 alphanumeric chars) | `/nick alice` |
| **`/join <room>`** | Switch to a chat room (auto-created if new) | `/join elixir` |
| **`/rooms`** | List all active chat rooms and user counts | `/rooms` |
| **`/users`** or **`/who`** | List all users in your current room | `/users` |
| **`/msg <user> <msg>`** | Send a private direct message to a user | `/msg bob Hello secret!` |
| **`/help`** | Display command list | `/help` |
| **`/quit`** | Disconnect cleanly from the server | `/quit` |
| *(any text)* | Broadcasts message to everyone in your current room | `Hello everyone!` |

---

## Getting Started

### 1. Start the Live Server

Start the chat server from your project root:

```bash
# On Linux / macOS:
iex -S mix
# or without IEx shell:
mix run --no-halt
```

```powershell
# On Windows PowerShell:
# (Note: In PowerShell, 'iex' is an alias for Invoke-Expression, so use iex.bat or mix run)
mix run --no-halt
# or with interactive IEx shell:
iex.bat -S mix
```

The server will initialize and begin listening on port `4040`:
```text
[info] ChatServer TCP Listener started on port 4040.
```

---

### 2. Connect Clients

Keep your server terminal running, then open one or more **new** terminal tabs or windows:

#### Option A: Built-in Terminal Client (Recommended)
```bash
elixir client.exs                  # connects to 127.0.0.1:4040
elixir client.exs 192.168.1.20     # custom host, default port
elixir client.exs chat.local 5000  # custom host and port
elixir client.exs --help           # show usage
```

| Argument | Default | Description |
| :--- | :--- | :--- |
| `host` | `127.0.0.1` | Server hostname or IP address |
| `port` | `4040` | Server TCP port (1–65535) |

Client behavior:
- Gives up after **5 seconds** if the server can't be reached, with a readable reason (for example `connection refused (is the server running?)` or `unknown host`).
- To disconnect, type `/quit` or press **Ctrl+D** (on Windows, **Ctrl+Z** then **Enter**).
- **Exit codes:** `0` for a normal disconnect, `1` for a connection or network error, `2` for invalid arguments. This makes the client usable in scripts.

You will see:
```text
Connecting to 127.0.0.1:4040...
=============================================================
         Welcome to Elixir BEAM TCP Chat Server!            
=============================================================
You are connected as: guest1 in room #lobby
Type /help to see all commands. Start chatting below!
-------------------------------------------------------------
```

Open a second terminal window, run `elixir client.exs` again, and you can chat live between the two windows!

#### Option B: Using Netcat / Telnet (Linux / macOS / Git Bash)
```bash
nc localhost 4040
# or:
telnet localhost 4040
```

#### Option C: Native Windows PowerShell
```powershell
$client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 4040)
$stream = $client.GetStream()
$reader = New-Object System.IO.StreamReader($stream)
$writer = New-Object System.IO.StreamWriter($stream); $writer.AutoFlush = $true

# Read welcome banner in background
[System.Threading.Tasks.Task]::Run({
    while ($line = $reader.ReadLine()) { [Console]::WriteLine($line) }
})

# Send commands / messages
$writer.WriteLine("/nick myname")
$writer.WriteLine("Hello from PowerShell!")
```

---

### 3. Run the Multi-User Bot Demo

Simulates 3 users (Alice, Bob, and Charlie) connecting simultaneously over TCP, chatting, changing rooms, sending private messages, and disconnecting:

```bash
# If your server is ALREADY running:
mix run --no-start bot_demo.exs
# or:
elixir bot_demo.exs

# If your server is NOT running (will start server automatically):
mix run bot_demo.exs
```

---

### 4. Run the Automated Test Suite

Run the full ExUnit test suite including unit tests and real TCP network integration tests:

> [!NOTE]
> Make sure no live server is currently running on port `4040` before running tests to avoid port conflict (`:eaddrinuse`).

```bash
mix test
```

Expected output:
```text
ChatServer TCP Listener started on port 4040.
......
Finished in 0.3 seconds
6 passed
```

---

## Project Structure

```
.
├── lib/
│   ├── chat_server/
│   │   ├── application.ex       # Supervisor tree root
│   │   ├── client_handler.ex    # Per-connection socket process (active mode)
│   │   ├── listener.ex          # TCP socket acceptor
│   │   └── room_manager.ex      # Room & user routing GenServer
│   └── chat_server.ex           # Main library entrypoint
├── test/
│   └── chat_server_test.exs     # Unit & TCP integration tests
├── bot_demo.exs                 # 3-bot automated simulation
├── client.exs                   # Interactive terminal chat client (elixir client.exs --help)
├── mix.exs                      # Project configuration
└── README.md                    # Documentation
```
#
