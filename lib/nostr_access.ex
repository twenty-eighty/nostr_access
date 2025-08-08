defmodule NostrAccess do
  @moduledoc """
  nostr_access - Elixir library for querying Nostr relays with caching and deduplication.

  ## Features

  - Query multiple Nostr relays simultaneously
  - Automatic event deduplication following NIP-01 rules
  - In-memory caching with configurable TTL
  - Connection pooling with automatic reconnection
  - Both synchronous (`fetch/3`) and asynchronous (`stream/3`) APIs

  ## Quick Start

      # Fetch events from a single relay
      {:ok, events} = Nostr.Client.fetch(["wss://relay.example.com"], %{kinds: [1]})

      # Stream events from multiple relays
      {:ok, ref} = Nostr.Client.stream(["wss://relay1.com", "wss://relay2.com"], %{authors: ["pubkey"]})

      # Receive events
      receive do
        {:nostr_event, ^ref, event} -> event
        {:nostr_eose, ^ref, true} -> :done
      end

  ## Configuration

  ```elixir
  config :nostr_access,
    idle_ms: 500,
    overall_timeout: 30_000,
    cache?: true,
    dedup_strategy: Nostr.Dedup.Default
  ```

  ## Architecture

  The library uses a supervision tree with:
  - Connection pools (≤3 connections per relay)
  - Subscription limits (≤10 subscriptions per connection)
  - Automatic idle timeout (500ms default)
  - Cache with TTL (2h for events, 10min for misses)
  """

  # Re-export the main client API
  alias Nostr.Client

  defdelegate fetch(relays, filter, opts \\ []), to: Client
  defdelegate stream(relays, filter, opts \\ []), to: Client
  defdelegate cancel(query_ref), to: Client

  @doc """
  Returns the version of nostr_access.
  """
  def version do
    {:ok, version} = :application.get_key(:nostr_access, :vsn)
    version
  end
end
