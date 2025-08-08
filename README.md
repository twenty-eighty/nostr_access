# nostr_access

An Elixir library for querying Nostr relays with caching and deduplication.

## Features

- **Multi-relay queries**: Query multiple Nostr relays simultaneously
- **Automatic deduplication**: Follows NIP-01 rules for event deduplication
- **In-memory caching**: Configurable TTL for events (2h) and misses (10min)
- **Connection pooling**: Up to 3 connections per relay with ≤10 subscriptions each
- **Dual API**: Both synchronous (`fetch/3`) and asynchronous (`stream/3`) interfaces
- **Automatic timeouts**: Idle timeout (500ms) and overall timeout (30s) handling

## Installation

Add `nostr_access` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nostr_access, "~> 0.1.0"}
  ]
end
```

## Quick Start

### Command Line Interface

The `nostr_access` package includes a command-line tool that follows the `nak` tool syntax:

```bash
# Build the CLI tool
mix escript.build

# Generate a filter for kind 1 events
./nostr_access --bare -k 1 -l 10

# Query multiple relays
./nostr_access -k 1 -l 15 wss://relay.example.com wss://nostr-pub.wellorder.net

# Use multiple authors and kinds
./nostr_access --bare -a pubkey1 -a pubkey2 -k 1 -k 6

# With tags and time filters
./nostr_access --bare -k 1 -t e=event123 -s 1700000000 -u 1700003600

# Stream events in real-time
./nostr_access --stream -k 1 wss://relay.example.com

# Paginate through events
./nostr_access --paginate --paginate-global-limit 100 -k 1 wss://relay.example.com
```

### Programmatic API

#### Fetching Events (Synchronous)

```elixir
# Fetch text notes from a single relay
{:ok, events} = Nostr.Client.fetch(
  ["wss://relay.example.com"],
  %{kinds: [1]}
)

# Fetch events from multiple relays
{:ok, events} = Nostr.Client.fetch(
  ["wss://relay1.com", "wss://relay2.com"],
  %{authors: ["pubkey1", "pubkey2"], kinds: [1, 6]}
)

# With custom options
{:ok, events} = Nostr.Client.fetch(
  ["wss://relay.example.com"],
  %{kinds: [1]},
  idle_ms: 1000,
  overall_timeout: 60_000,
  cache?: false
)
```

#### Streaming Events (Asynchronous)

```elixir
# Start a streaming query
{:ok, query_ref} = Nostr.Client.stream(
  ["wss://relay1.com", "wss://relay2.com"],
  %{kinds: [1]}
)

# Receive events
receive do
  {:nostr_event, ^query_ref, event} ->
    IO.puts("Received event: #{event["id"]}")
    
  {:nostr_eose, ^query_ref, true} ->
    IO.puts("All relays finished")
    
  {:nostr_eose, ^query_ref, false} ->
    IO.puts("One relay finished")
end

# Cancel a streaming query
Nostr.Client.cancel(query_ref)
```

## Configuration

Configure `nostr_access` in your `config/config.exs`:

```elixir
config :nostr_access,
  idle_ms: 500,                    # Inactivity window (ms)
  overall_timeout: 30_000,         # Hard stop timeout (ms)
  cache?: true,                    # Enable/disable caching
  dedup_strategy: Nostr.Dedup.Default  # Deduplication strategy
```

## CLI Reference

The `nostr_access` command-line tool follows the `nak` tool syntax for compatibility:

### Usage

```bash
nostr_access [options] [relay...]
```

### Options

#### Filter Attributes
- `--author, -a` - Only accept events from these authors (pubkey as hex)
- `--id, -i` - Only accept events with these ids (hex)
- `--kind, -k` - Only accept events with these kind numbers
- `--limit, -l` - Only accept up to this number of events
- `--search` - NIP-50 search query (relay support required)
- `--since, -s` - Only accept events newer than this (unix timestamp)
- `--tag, -t` - Takes a tag like `-t e=<id>`, only accept events with these tags
- `--until, -u` - Only accept events older than this (unix timestamp)
- `-d` - Shortcut for `--tag d=<value>`
- `-e` - Shortcut for `--tag e=<value>`
- `-p` - Shortcut for `--tag p=<value>`

#### Output Options
- `--bare` - Print just the filter, not enveloped in a `["REQ", ...]` array
- `--ids-only` - Fetch just a list of event IDs
- `--stream` - Keep subscription open, print events as they arrive
- `--paginate` - Make multiple REQs decreasing 'until' until conditions met
- `--paginate-global-limit` - Global limit for pagination
- `--paginate-interval` - Time between pagination queries (e.g., "5s", "1m")

#### Global Options
- `--help, -h` - Show help
- `--quiet, -q` - Suppress logs and info messages
- `--verbose, -v` - Print more detailed information
- `--version` - Print version

### Examples

```bash
# Generate a filter for kind 1 events
./nostr_access --bare -k 1 -l 10

# Query multiple relays
./nostr_access -k 1 -l 15 wss://relay.example.com wss://nostr-pub.wellorder.net

# Use multiple authors and kinds
./nostr_access --bare -a pubkey1 -a pubkey2 -k 1 -k 6

# With tags and time filters
./nostr_access --bare -k 1 -t e=event123 -s 1700000000 -u 1700003600

# Stream events in real-time
./nostr_access --stream -k 1 wss://relay.example.com

# Paginate through events
./nostr_access --paginate --paginate-global-limit 100 -k 1 wss://relay.example.com
```

## API Reference

### `Nostr.Client.fetch/3`

Fetches events from relays synchronously.

```elixir
@spec fetch([relay_uri], filter, Keyword.t()) :: {:ok, [event]} | {:error, term()}
```

**Options:**
- `:idle_ms` - Inactivity window in milliseconds (default: 500)
- `:overall_timeout` - Hard stop timeout in milliseconds (default: 30_000)
- `:cache?` - Enable/disable caching (default: true)
- `:dedup_strategy` - Deduplication strategy module (default: Nostr.Dedup.Default)

### `Nostr.Client.stream/3`

Starts a streaming query to relays.

```elixir
@spec stream([relay_uri], filter, Keyword.t()) :: {:ok, query_ref} | {:error, term()}
```

**Messages received:**
- `{:nostr_event, query_ref, event}` - When a new event arrives
- `{:nostr_eose, query_ref, done?}` - When a relay sends EOSE

### `Nostr.Client.cancel/1`

Cancels a streaming query.

```elixir
@spec cancel(query_ref) :: :ok | {:error, :not_found}
```

## Filter Examples

```elixir
# Text notes from specific authors
%{kinds: [1], authors: ["pubkey1", "pubkey2"]}

# Recent events
%{kinds: [1], since: System.system_time(:second) - 3600}

# Events with specific tags
%{kinds: [1], "#t" => ["nostr", "elixir"]}

# Addressable events
%{kinds: [30000], authors: ["pubkey"], "#d" => ["identifier"]}

# Limited results
%{kinds: [1], limit: 100}
```

## Architecture

The library uses a supervision tree with the following components:

```
nostr_access.Application (Supervisor, :rest_for_one)
├─ Registry.NostrQueries              # {query_ref, pid}
├─ Nostr.Cache.Events   (Cachex, TTL 2 h)
├─ Nostr.Cache.Miss     (Cachex, TTL 10 min)
├─ Nostr.Telemetry.Supervisor
├─ DynamicSupervisor.QuerySup         # one Nostr.Query per request
└─ DynamicSupervisor.RelayPoolSup     # one per relay URI
    └─ Nostr.RelayPool (GenServer)
        └─ 0–3 Nostr.Connection (WebSockex)   # ≤10 subs each
```

## Deduplication Strategy

The library follows NIP-01 rules for event deduplication:

| Event Class | Uniqueness Key |
|-------------|----------------|
| Addressable (kind 30000-39999) | `{kind, pubkey, d_tag}` |
| Lists & Metadata (kind 0, 10000-19999) | `{kind, pubkey}` |
| All other kinds | `event.id` |

You can implement custom deduplication strategies by implementing the `Nostr.Dedup` behaviour.

## Testing

Run the test suite:

```bash
mix test
```

Run with coverage:

```bash
MIX_ENV=test mix test --cover
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built for the Nostr protocol (NIP-01)
- Uses WebSockex for WebSocket connections
- Uses Cachex for in-memory caching

