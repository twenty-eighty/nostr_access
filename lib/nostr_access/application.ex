defmodule NostrAccess.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize ETS table for relay pool locks
    :ets.new(:relay_pool_locks, [:set, :public, :named_table])

    children = [
      # Registry for Nostr queries
      {Registry, keys: :unique, name: Registry.NostrQueries},

      # Registry for Nostr connections
      {Registry, keys: :unique, name: Registry.NostrConnections},

      # Registry for Nostr relay pools
      {Registry, keys: :unique, name: Registry.NostrRelayPools},

      # Cache for zero results (TTL: 1 hour)
      Supervisor.child_spec({Cachex, name: :nostr_cache_zero_results, default_ttl: 3_600_000},
        id: :nostr_cache_zero_results
      ),

      # Cache for immutable results - queries with specific event IDs (TTL: 1 day)
      Supervisor.child_spec({Cachex, name: :nostr_cache_immutable, default_ttl: 86_400_000},
        id: :nostr_cache_immutable
      ),

      # Cache for mutable results - all other queries (TTL: 30 minutes)
      Supervisor.child_spec({Cachex, name: :nostr_cache_mutable, default_ttl: 1_800_000},
        id: :nostr_cache_mutable
      ),
      # Cache for relay health tracking (TTL: 24 hours)
      Supervisor.child_spec(
        {Cachex, name: :nostr_relay_health_cache, ttl_interval: :timer.minutes(60)},
        id: :nostr_relay_health_cache
      ),

      # Telemetry supervisor
      Nostr.Telemetry.Supervisor,

      # Dynamic supervisor for queries
      {DynamicSupervisor, name: DynamicSupervisor.QuerySup, strategy: :one_for_one},

      # Dynamic supervisor for relay pools
      {DynamicSupervisor, name: DynamicSupervisor.RelayPoolSup, strategy: :one_for_one},

      # Dynamic supervisor for publishers
      {DynamicSupervisor, name: DynamicSupervisor.PublisherSup, strategy: :one_for_one}
    ]

    opts = [strategy: :rest_for_one, name: NostrAccess.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
