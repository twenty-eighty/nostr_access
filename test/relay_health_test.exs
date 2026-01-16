defmodule NostrAccess.RelayHealthTest do
  use ExUnit.Case, async: false

  alias NostrAccess.RelayHealth

  setup do
    Cachex.clear(:nostr_relay_health_cache)
    :ok
  end

  test "drops relays in cooldown when others are healthy" do
    bad = "wss://relay.bad.example"
    good = "wss://relay.good.example"

    RelayHealth.record_failure(bad, :error)
    RelayHealth.record_failure(bad, :error)
    RelayHealth.record_failure(bad, :error)

    relays = RelayHealth.available_relays([bad, good])

    assert good in relays
    refute bad in relays
  end

  test "falls back to all relays when none are healthy" do
    first = "wss://relay.first.example"
    second = "wss://relay.second.example"

    for _ <- 1..3 do
      RelayHealth.record_failure(first, :error)
      RelayHealth.record_failure(second, :error)
    end

    relays = RelayHealth.available_relays([first, second])

    assert Enum.sort(relays) == Enum.sort([first, second])
  end
end
