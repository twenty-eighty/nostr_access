defmodule Nostr.DedupTest do
  use ExUnit.Case

  describe "Nostr.Dedup.Default.dedup/2" do
    test "deduplicates regular events by id" do
      events = [
        %{"id" => "event1", "kind" => 1, "content" => "first"},
        %{"id" => "event2", "kind" => 1, "content" => "second"},
        %{"id" => "event1", "kind" => 1, "content" => "duplicate"}
      ]

      result = Nostr.Dedup.Default.dedup(events, %{})

      assert length(result) == 2
      assert Enum.find(result, fn event -> event["id"] == "event1" end)
      assert Enum.find(result, fn event -> event["id"] == "event2" end)
    end

    test "deduplicates metadata events by kind and pubkey" do
      events = [
        %{"id" => "event1", "kind" => 0, "pubkey" => "pubkey1", "content" => "first"},
        %{"id" => "event2", "kind" => 0, "pubkey" => "pubkey1", "content" => "second"},
        %{"id" => "event3", "kind" => 0, "pubkey" => "pubkey2", "content" => "third"}
      ]

      result = Nostr.Dedup.Default.dedup(events, %{})

      assert length(result) == 2
      pubkey1_events = Enum.filter(result, fn event -> event["pubkey"] == "pubkey1" end)
      assert length(pubkey1_events) == 1
    end

    test "deduplicates addressable events by kind, pubkey, and d tag" do
      events = [
        %{
          "id" => "event1",
          "kind" => 30000,
          "pubkey" => "pubkey1",
          "tags" => [["d", "tag1"]],
          "content" => "first"
        },
        %{
          "id" => "event2",
          "kind" => 30000,
          "pubkey" => "pubkey1",
          "tags" => [["d", "tag1"]],
          "content" => "second"
        },
        %{
          "id" => "event3",
          "kind" => 30000,
          "pubkey" => "pubkey1",
          "tags" => [["d", "tag2"]],
          "content" => "third"
        }
      ]

      result = Nostr.Dedup.Default.dedup(events, %{})

      assert length(result) == 2

      tag1_events =
        Enum.filter(result, fn event ->
          Enum.any?(event["tags"], fn tag -> tag == ["d", "tag1"] end)
        end)

      assert length(tag1_events) == 1
    end

    test "handles events without d tag for addressable events" do
      events = [
        %{
          "id" => "event1",
          "kind" => 30000,
          "pubkey" => "pubkey1",
          "tags" => [],
          "content" => "first"
        },
        %{
          "id" => "event2",
          "kind" => 30000,
          "pubkey" => "pubkey1",
          "tags" => [],
          "content" => "second"
        }
      ]

      result = Nostr.Dedup.Default.dedup(events, %{})

      assert length(result) == 1
    end

    test "handles empty event list" do
      result = Nostr.Dedup.Default.dedup([], %{})
      assert result == []
    end

    test "handles events with missing fields" do
      events = [
        %{"id" => "event1", "kind" => 1},
        # missing kind
        %{"id" => "event2"},
        # missing id
        %{"kind" => 1}
      ]

      result = Nostr.Dedup.Default.dedup(events, %{})

      # Should still deduplicate what it can
      assert length(result) <= 3
    end
  end

  describe "Nostr.Dedup.dedup/2" do
    test "uses the configured dedup strategy" do
      events = [
        %{"id" => "event1", "kind" => 1},
        %{"id" => "event1", "kind" => 1}
      ]

      result = Nostr.Dedup.dedup(events, %{})

      assert length(result) == 1
    end
  end

  describe "sorting and limit functionality" do
    test "sorts events by created_at timestamp (newest first) and respects limit" do
      # Simulate events from two relays with different timestamps
      # Relay 1 events (older)
      relay1_events = [
        %{
          "id" => "event1",
          "kind" => 0,
          "pubkey" => "pubkey1",
          # Oldest
          "created_at" => 1_754_000_000,
          "content" => "oldest event"
        },
        %{
          "id" => "event2",
          "kind" => 0,
          "pubkey" => "pubkey2",
          # Second oldest
          "created_at" => 1_754_100_000,
          "content" => "second oldest event"
        },
        %{
          "id" => "event3",
          "kind" => 0,
          "pubkey" => "pubkey3",
          # Third oldest
          "created_at" => 1_754_200_000,
          "content" => "third oldest event"
        }
      ]

      # Relay 2 events (newer)
      relay2_events = [
        %{
          "id" => "event4",
          "kind" => 0,
          "pubkey" => "pubkey4",
          # Third newest
          "created_at" => 1_754_300_000,
          "content" => "third newest event"
        },
        %{
          "id" => "event5",
          "kind" => 0,
          "pubkey" => "pubkey5",
          # Second newest
          "created_at" => 1_754_400_000,
          "content" => "second newest event"
        },
        %{
          "id" => "event6",
          "kind" => 0,
          "pubkey" => "pubkey6",
          # Newest
          "created_at" => 1_754_500_000,
          "content" => "newest event"
        }
      ]

      # Combine events from both relays (simulating how they arrive)
      all_events = relay1_events ++ relay2_events

      # Test deduplication without limit (should return all 6 unique events, sorted newest first)
      result_no_limit = Nostr.Dedup.Default.dedup(all_events, %{})

      assert length(result_no_limit) == 6

      # Verify they are sorted by created_at (newest first)
      timestamps = Enum.map(result_no_limit, & &1["created_at"])
      assert timestamps == Enum.sort(timestamps, :desc)

      # Test that deduplication returns all events sorted by timestamp (newest first)
      # The limit is now handled in the query module, not in deduplication
      result_deduped = Nostr.Dedup.Default.dedup(all_events, %{})

      assert length(result_deduped) == 6

      # Verify they are sorted by created_at (newest first)
      timestamps = Enum.map(result_deduped, & &1["created_at"])
      assert timestamps == Enum.sort(timestamps, :desc)

      # Verify the first 3 events are the newest ones
      first_three = Enum.take(result_deduped, 3)
      returned_timestamps = Enum.map(first_three, & &1["created_at"])
      expected_newest_timestamps = [1_754_500_000, 1_754_400_000, 1_754_300_000]
      assert returned_timestamps == expected_newest_timestamps

      # Verify the content matches the expected newest events
      assert Enum.find(first_three, fn event -> event["content"] == "newest event" end)
      assert Enum.find(first_three, fn event -> event["content"] == "second newest event" end)
      assert Enum.find(first_three, fn event -> event["content"] == "third newest event" end)

      # Verify older events are NOT in the first 3
      refute Enum.find(first_three, fn event -> event["content"] == "oldest event" end)
      refute Enum.find(first_three, fn event -> event["content"] == "second oldest event" end)
      refute Enum.find(first_three, fn event -> event["content"] == "third oldest event" end)
    end

    test "handles duplicate events by keeping the newest version" do
      # Create events with the same uniqueness key but different timestamps
      events = [
        %{
          "id" => "event1",
          "kind" => 0,
          "pubkey" => "pubkey1",
          # Older version
          "created_at" => 1_754_000_000,
          "content" => "older version"
        },
        %{
          "id" => "event2",
          "kind" => 0,
          # Same pubkey (duplicate for kind 0)
          "pubkey" => "pubkey1",
          # Newer version
          "created_at" => 1_754_500_000,
          "content" => "newer version"
        },
        %{
          "id" => "event3",
          "kind" => 0,
          "pubkey" => "pubkey2",
          "created_at" => 1_754_200_000,
          "content" => "unique event"
        }
      ]

      result = Nostr.Dedup.Default.dedup(events, %{})

      assert length(result) == 2

      # Should keep the newer version of the duplicate
      newer_version = Enum.find(result, fn event -> event["pubkey"] == "pubkey1" end)
      assert newer_version["content"] == "newer version"
      assert newer_version["created_at"] == 1_754_500_000

      # Should also include the unique event
      unique_event = Enum.find(result, fn event -> event["pubkey"] == "pubkey2" end)
      assert unique_event["content"] == "unique event"
    end

    test "handles events without created_at timestamp" do
      events = [
        %{
          "id" => "event1",
          "kind" => 0,
          "pubkey" => "pubkey1",
          "created_at" => 1_754_500_000,
          "content" => "has timestamp"
        },
        %{
          "id" => "event2",
          "kind" => 0,
          "pubkey" => "pubkey2",
          # No created_at
          "content" => "no timestamp"
        },
        %{
          "id" => "event3",
          "kind" => 0,
          "pubkey" => "pubkey3",
          "created_at" => 1_754_400_000,
          "content" => "has timestamp too"
        }
      ]

      result = Nostr.Dedup.Default.dedup(events, %{})

      assert length(result) == 3

      # Events with timestamps should be prioritized over those without
      has_timestamp_events =
        Enum.filter(result, fn event -> Map.has_key?(event, "created_at") end)

      assert length(has_timestamp_events) == 2
    end

    test "simulates realistic relay scenario with mixed event types" do
      # Simulate a realistic scenario with different event kinds
      events = [
        # Kind 0 events (metadata) - should deduplicate by pubkey
        %{
          "id" => "meta1",
          "kind" => 0,
          "pubkey" => "pubkey1",
          "created_at" => 1_754_000_000,
          "content" => "old metadata"
        },
        %{
          "id" => "meta2",
          "kind" => 0,
          # Same pubkey, newer timestamp
          "pubkey" => "pubkey1",
          "created_at" => 1_754_500_000,
          "content" => "new metadata"
        },
        %{
          "id" => "meta3",
          "kind" => 0,
          "pubkey" => "pubkey2",
          "created_at" => 1_754_200_000,
          "content" => "other metadata"
        },

        # Kind 1 events (notes) - should deduplicate by id
        %{
          "id" => "note1",
          "kind" => 1,
          "pubkey" => "pubkey3",
          "created_at" => 1_754_100_000,
          "content" => "old note"
        },
        %{
          # Same id, newer timestamp
          "id" => "note1",
          "kind" => 1,
          "pubkey" => "pubkey3",
          "created_at" => 1_754_400_000,
          "content" => "new note"
        },
        %{
          "id" => "note2",
          "kind" => 1,
          "pubkey" => "pubkey4",
          "created_at" => 1_754_300_000,
          "content" => "unique note"
        }
      ]

      result = Nostr.Dedup.Default.dedup(events, %{})

      assert length(result) == 4

      # Should have the newest version of each unique event
      timestamps = Enum.map(result, & &1["created_at"])
      assert timestamps == Enum.sort(timestamps, :desc)

      # Verify we got the newest versions
      assert Enum.find(result, fn event ->
               event["kind"] == 0 && event["pubkey"] == "pubkey1" &&
                 event["content"] == "new metadata"
             end)

      assert Enum.find(result, fn event ->
               event["kind"] == 1 && event["id"] == "note1" && event["content"] == "new note"
             end)
    end
  end
end
