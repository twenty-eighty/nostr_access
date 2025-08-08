defmodule Nostr.QueryTest do
  use ExUnit.Case

  describe "query limit functionality" do
    test "applies limit after deduplication and returns newest events" do
      # Simulate events from two relays
      relay1_events = [
        %{
          "id" => "event1",
          "kind" => 0,
          "pubkey" => "pubkey1",
          "created_at" => 1754000000,  # Oldest
          "content" => "oldest event"
        },
        %{
          "id" => "event2",
          "kind" => 0,
          "pubkey" => "pubkey2",
          "created_at" => 1754100000,  # Second oldest
          "content" => "second oldest event"
        },
        %{
          "id" => "event3",
          "kind" => 0,
          "pubkey" => "pubkey3",
          "created_at" => 1754200000,  # Third oldest
          "content" => "third oldest event"
        }
      ]

      relay2_events = [
        %{
          "id" => "event4",
          "kind" => 0,
          "pubkey" => "pubkey4",
          "created_at" => 1754300000,  # Third newest
          "content" => "third newest event"
        },
        %{
          "id" => "event5",
          "kind" => 0,
          "pubkey" => "pubkey5",
          "created_at" => 1754400000,  # Second newest
          "content" => "second newest event"
        },
        %{
          "id" => "event6",
          "kind" => 0,
          "pubkey" => "pubkey6",
          "created_at" => 1754500000,  # Newest
          "content" => "newest event"
        }
      ]

      # Combine all events (simulating how they arrive from multiple relays)
      all_events = relay1_events ++ relay2_events

      # Test the complete flow: deduplication + limit
      # First, deduplicate (this is what the dedup module does)
      deduped_events = Nostr.Dedup.Default.dedup(all_events, %{})

      # Then apply limit (this is what the query module does)
      final_events = Enum.take(deduped_events, 3)

      # Verify we get exactly 3 events
      assert length(final_events) == 3

      # Verify they are the 3 newest events
      returned_timestamps = Enum.map(final_events, & &1["created_at"])
      expected_newest_timestamps = [1754500000, 1754400000, 1754300000]
      assert returned_timestamps == expected_newest_timestamps

      # Verify the content matches the expected newest events
      assert Enum.find(final_events, fn event -> event["content"] == "newest event" end)
      assert Enum.find(final_events, fn event -> event["content"] == "second newest event" end)
      assert Enum.find(final_events, fn event -> event["content"] == "third newest event" end)

      # Verify older events are NOT included
      refute Enum.find(final_events, fn event -> event["content"] == "oldest event" end)
      refute Enum.find(final_events, fn event -> event["content"] == "second oldest event" end)
      refute Enum.find(final_events, fn event -> event["content"] == "third oldest event" end)
    end

    test "handles duplicate events across relays by keeping newest version" do
      # Simulate the same event appearing on multiple relays with different timestamps
      relay1_duplicate = %{
        "id" => "event1",
        "kind" => 0,
        "pubkey" => "pubkey1",
        "created_at" => 1754000000,  # Older version
        "content" => "older version"
      }

      relay2_duplicate = %{
        "id" => "event2",  # Different ID but same pubkey (kind 0 deduplicates by pubkey)
        "kind" => 0,
        "pubkey" => "pubkey1",  # Same pubkey
        "created_at" => 1754500000,  # Newer version
        "content" => "newer version"
      }

      unique_event = %{
        "id" => "event3",
        "kind" => 0,
        "pubkey" => "pubkey2",
        "created_at" => 1754200000,
        "content" => "unique event"
      }

      all_events = [relay1_duplicate, relay2_duplicate, unique_event]

      # Test the complete flow
      deduped_events = Nostr.Dedup.Default.dedup(all_events, %{})
      final_events = Enum.take(deduped_events, 2)

      assert length(final_events) == 2

      # Should keep the newer version of the duplicate
      newer_version = Enum.find(final_events, fn event -> event["pubkey"] == "pubkey1" end)
      assert newer_version["content"] == "newer version"
      assert newer_version["created_at"] == 1754500000

      # Should also include the unique event
      unique_event_result = Enum.find(final_events, fn event -> event["pubkey"] == "pubkey2" end)
      assert unique_event_result["content"] == "unique event"
    end

    test "simulates realistic scenario with mixed event types and limits" do
      # Simulate a realistic scenario with different event kinds from multiple relays
      events = [
        # Kind 0 events (metadata) - should deduplicate by pubkey
        %{
          "id" => "meta1",
          "kind" => 0,
          "pubkey" => "pubkey1",
          "created_at" => 1754000000,
          "content" => "old metadata"
        },
        %{
          "id" => "meta2",
          "kind" => 0,
          "pubkey" => "pubkey1",  # Same pubkey, newer timestamp
          "created_at" => 1754500000,
          "content" => "new metadata"
        },
        %{
          "id" => "meta3",
          "kind" => 0,
          "pubkey" => "pubkey2",
          "created_at" => 1754200000,
          "content" => "other metadata"
        },

        # Kind 1 events (notes) - should deduplicate by id
        %{
          "id" => "note1",
          "kind" => 1,
          "pubkey" => "pubkey3",
          "created_at" => 1754100000,
          "content" => "old note"
        },
        %{
          "id" => "note1",  # Same id, newer timestamp
          "kind" => 1,
          "pubkey" => "pubkey3",
          "created_at" => 1754400000,
          "content" => "new note"
        },
        %{
          "id" => "note2",
          "kind" => 1,
          "pubkey" => "pubkey4",
          "created_at" => 1754300000,
          "content" => "unique note"
        }
      ]

      # Test the complete flow
      deduped_events = Nostr.Dedup.Default.dedup(events, %{})
      final_events = Enum.take(deduped_events, 3)

      assert length(final_events) == 3

      # Should have the newest version of each unique event
      timestamps = Enum.map(final_events, & &1["created_at"])
      assert timestamps == Enum.sort(timestamps, :desc)

      # Verify we got the newest versions
      assert Enum.find(final_events, fn event ->
        event["kind"] == 0 && event["pubkey"] == "pubkey1" && event["content"] == "new metadata"
      end)

      assert Enum.find(final_events, fn event ->
        event["kind"] == 1 && event["id"] == "note1" && event["content"] == "new note"
      end)
    end
  end

  describe "cache integration" do
    setup do
      # Clear cache before each test
      Cachex.clear(:nostr_cache_zero_results)
      Cachex.clear(:nostr_cache_immutable)
      Cachex.clear(:nostr_cache_mutable)
      :ok
    end

    test "cache key generation is consistent for same query" do
      relays = ["wss://relay2.com", "wss://relay1.com"]
      filter = %{kinds: [0], limit: 3}

      # Generate cache key
      cache_key = Nostr.Cache.make_key(relays, filter)

      # Verify it's a tuple with sorted relays and encoded filter
      assert is_tuple(cache_key)
      {sorted_relays, encoded_filter} = cache_key
      assert sorted_relays == ["wss://relay1.com", "wss://relay2.com"]
      assert is_binary(encoded_filter)
    end

    test "cache stores and retrieves mutable events correctly" do
      cache_key = {["wss://relay1.com", "wss://relay2.com"], "filter_hash"}
      filter = %{kinds: [0]}
      events = [
        %{
          "id" => "event1",
          "kind" => 0,
          "pubkey" => "pubkey1",
          "created_at" => 1754500000,
          "content" => "test event"
        }
      ]

      # Store events in cache
      assert {:ok, true} = Nostr.Cache.put_events(cache_key, events, filter)

      # Retrieve events from cache
      assert {:ok, cached_events} = Nostr.Cache.get_events(cache_key, filter)
      assert length(cached_events) == 1
      assert hd(cached_events)["id"] == "event1"
    end

    test "cache stores and retrieves immutable events correctly" do
      cache_key = {["wss://relay1.com", "wss://relay2.com"], "filter_hash"}
      filter = %{ids: ["event1"]}
      events = [
        %{
          "id" => "event1",
          "kind" => 0,
          "pubkey" => "pubkey1",
          "created_at" => 1754500000,
          "content" => "test event"
        }
      ]

      # Store events in cache
      assert {:ok, true} = Nostr.Cache.put_events(cache_key, events, filter)

      # Retrieve events from cache
      assert {:ok, cached_events} = Nostr.Cache.get_events(cache_key, filter)
      assert length(cached_events) == 1
      assert hd(cached_events)["id"] == "event1"
    end

    test "cache stores and retrieves zero results correctly" do
      cache_key = {["wss://relay1.com", "wss://relay2.com"], "filter_hash"}

      # Store zero results in cache
      assert {:ok, true} = Nostr.Cache.put_zero_results(cache_key, [])

      # Retrieve zero results from cache
      assert {:ok, []} = Nostr.Cache.get_zero_results(cache_key)
    end

    test "cache handles get_or_store for mutable events" do
      cache_key = {["wss://relay1.com", "wss://relay2.com"], "filter_hash"}
      filter = %{kinds: [0]}
      events = [%{"id" => "event1", "kind" => 0, "pubkey" => "pubkey1"}]

      # First call should execute the function
      result1 = Nostr.Cache.get_or_store(cache_key, filter, fn -> events end)
      assert result1 == events

      # Second call should return cached value
      result2 = Nostr.Cache.get_or_store(cache_key, filter, fn -> [%{"id" => "event2"}] end)
      assert result2 == events
    end

    test "cache handles get_or_store for immutable events" do
      cache_key = {["wss://relay1.com", "wss://relay2.com"], "filter_hash"}
      filter = %{ids: ["event1"]}
      events = [%{"id" => "event1", "kind" => 0, "pubkey" => "pubkey1"}]

      # First call should execute the function
      result1 = Nostr.Cache.get_or_store(cache_key, filter, fn -> events end)
      assert result1 == events

      # Second call should return cached value
      result2 = Nostr.Cache.get_or_store(cache_key, filter, fn -> [%{"id" => "event2"}] end)
      assert result2 == events
    end

    test "cache handles get_or_store for zero results" do
      cache_key = {["wss://relay1.com", "wss://relay2.com"], "filter_hash"}
      filter = %{kinds: [0]}

      # First call should execute the function
      result1 = Nostr.Cache.get_or_store(cache_key, filter, fn -> [] end)
      assert result1 == []

      # Second call should return cached miss
      result2 = Nostr.Cache.get_or_store(cache_key, filter, fn -> [%{"id" => "event1"}] end)
      assert result2 == []
    end
  end
end
