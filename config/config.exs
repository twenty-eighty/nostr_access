# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
import Config

# Configure nostr_access
config :nostr_access,
  idle_ms: 500,
  overall_timeout: 30_000,
  cache?: true,
  dedup_strategy: Nostr.Dedup.Default

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
