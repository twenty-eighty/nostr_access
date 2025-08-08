defmodule Nostr.CacheTest do
  use ExUnit.Case

  setup do
    # Clear cache before each test
    Cachex.clear(:nostr_cache_zero_results)
    Cachex.clear(:nostr_cache_immutable)
    Cachex.clear(:nostr_cache_mutable)
    :ok
  end

  describe "make_key/2" do
    test "creates a consistent key from relays and filter" do
      relays = ["wss://relay1.com", "wss://relay2.com"]
      filter = %{kinds: [1, 2], authors: ["pubkey"]}

      key1 = Nostr.Cache.make_key(relays, filter)
      key2 = Nostr.Cache.make_key(Enum.reverse(relays), filter)

      assert key1 == key2
    end

    test "sorts relays and encodes filter" do
      relays = ["wss://relay2.com", "wss://relay1.com"]
      filter = %{kinds: [2, 1]}

      key = Nostr.Cache.make_key(relays, filter)

      assert is_tuple(key)
      assert tuple_size(key) == 2
      {sorted_relays, encoded_filter} = key
      assert sorted_relays == ["wss://relay1.com", "wss://relay2.com"]
      assert is_binary(encoded_filter)
    end
  end

  describe "get_or_store/3" do
    test "stores and retrieves mutable events" do
      key = {["relay"], "filter"}
      filter = %{kinds: [1]}
      events = [%{"id" => "event1"}]

      # First call should execute the function
      result1 = Nostr.Cache.get_or_store(key, filter, fn -> events end)
      assert result1 == events

      # Second call should return cached value
      result2 = Nostr.Cache.get_or_store(key, filter, fn -> [%{"id" => "event2"}] end)
      assert result2 == events
    end

    test "stores and retrieves immutable events" do
      key = {["relay"], "filter"}
      filter = %{ids: ["event1", "event2"]}
      events = [%{"id" => "event1"}]

      # First call should execute the function
      result1 = Nostr.Cache.get_or_store(key, filter, fn -> events end)
      assert result1 == events

      # Second call should return cached value
      result2 = Nostr.Cache.get_or_store(key, filter, fn -> [%{"id" => "event2"}] end)
      assert result2 == events
    end

    test "stores and retrieves zero results" do
      key = {["relay"], "filter"}
      filter = %{kinds: [1]}

      # First call should execute the function
      result1 = Nostr.Cache.get_or_store(key, filter, fn -> [] end)
      assert result1 == []

      # Second call should return cached miss
      result2 = Nostr.Cache.get_or_store(key, filter, fn -> [%{"id" => "event1"}] end)
      assert result2 == []
    end

    test "handles cache errors gracefully" do
      key = {["relay"], "filter"}
      filter = %{kinds: [1]}
      events = [%{"id" => "event1"}]

      # Should still execute function even if cache fails
      result = Nostr.Cache.get_or_store(key, filter, fn -> events end)
      assert result == events
    end
  end

  describe "get_events/2" do
    test "retrieves mutable events from cache" do
      key = {["relay"], "filter"}
      filter = %{kinds: [1]}
      events = [%{"id" => "event1"}]

      Cachex.put(:nostr_cache_mutable, key, events)

      assert {:ok, ^events} = Nostr.Cache.get_events(key, filter)
    end

    test "retrieves immutable events from cache" do
      key = {["relay"], "filter"}
      filter = %{ids: ["event1"]}
      events = [%{"id" => "event1"}]

      Cachex.put(:nostr_cache_immutable, key, events)

      assert {:ok, ^events} = Nostr.Cache.get_events(key, filter)
    end

    test "returns nil for missing events" do
      key = {["relay"], "filter"}
      filter = %{kinds: [1]}

      assert {:ok, nil} = Nostr.Cache.get_events(key, filter)
    end
  end

  describe "get_zero_results/1" do
    test "retrieves zero results from cache" do
      key = {["relay"], "filter"}

      Cachex.put(:nostr_cache_zero_results, key, [])

      assert {:ok, []} = Nostr.Cache.get_zero_results(key)
    end

    test "returns nil for missing zero results" do
      key = {["relay"], "filter"}

      assert {:ok, nil} = Nostr.Cache.get_zero_results(key)
    end
  end

  describe "put_events/3" do
    test "stores mutable events in cache" do
      key = {["relay"], "filter"}
      filter = %{kinds: [1]}
      events = [%{"id" => "event1"}]

      assert {:ok, true} = Nostr.Cache.put_events(key, events, filter)
      assert {:ok, ^events} = Nostr.Cache.get_events(key, filter)
    end

    test "stores immutable events in cache" do
      key = {["relay"], "filter"}
      filter = %{ids: ["event1"]}
      events = [%{"id" => "event1"}]

      assert {:ok, true} = Nostr.Cache.put_events(key, events, filter)
      assert {:ok, ^events} = Nostr.Cache.get_events(key, filter)
    end
  end

  describe "put_zero_results/2" do
    test "stores zero results in cache" do
      key = {["relay"], "filter"}

      assert {:ok, true} = Nostr.Cache.put_zero_results(key, [])
      assert {:ok, []} = Nostr.Cache.get_zero_results(key)
    end
  end

  describe "determine_cache_table/2" do
    test "returns zero results table for empty results" do
      filter = %{kinds: [1]}
      results = []

      table = Nostr.Cache.determine_cache_table(filter, results)
      assert table == :nostr_cache_zero_results
    end

    test "returns immutable table for queries with specific event IDs" do
      filter = %{ids: ["event1", "event2"]}
      results = [%{"id" => "event1"}]

      table = Nostr.Cache.determine_cache_table(filter, results)
      assert table == :nostr_cache_immutable
    end

    test "returns mutable table for queries without specific event IDs" do
      filter = %{kinds: [1], authors: ["pubkey1"]}
      results = [%{"id" => "event1"}]

      table = Nostr.Cache.determine_cache_table(filter, results)
      assert table == :nostr_cache_mutable
    end

    test "returns mutable table for queries with empty ids list" do
      filter = %{ids: []}
      results = [%{"id" => "event1"}]

      table = Nostr.Cache.determine_cache_table(filter, results)
      assert table == :nostr_cache_mutable
    end
  end
end
