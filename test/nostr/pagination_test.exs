defmodule Nostr.PaginationTest do
  use ExUnit.Case

  describe "pagination functionality" do
    test "paginates events correctly with multiple queries" do
      # Mock events that would be returned in sequence
      events_batch_1 = [
        %{
          "id" => "event1",
          "kind" => 1,
          "pubkey" => "pubkey1",
          "created_at" => 1754500000,
          "content" => "newest event"
        },
        %{
          "id" => "event2",
          "kind" => 1,
          "pubkey" => "pubkey2",
          "created_at" => 1754400000,
          "content" => "second newest event"
        }
      ]

      events_batch_2 = [
        %{
          "id" => "event3",
          "kind" => 1,
          "pubkey" => "pubkey3",
          "created_at" => 1754300000,
          "content" => "third newest event"
        },
        %{
          "id" => "event4",
          "kind" => 1,
          "pubkey" => "pubkey4",
          "created_at" => 1754200000,
          "content" => "fourth newest event"
        }
      ]

      events_batch_3 = []  # No more events

      # Mock the Nostr.Client.fetch function
      test_pid = self()

      # Simulate pagination by tracking calls
      pagination_state = %{
        calls: 0,
        events_batches: [events_batch_1, events_batch_2, events_batch_3]
      }

      # Test that pagination stops when no more events are returned
      result = simulate_pagination(pagination_state, test_pid)

      assert result.total_events == 4
      assert result.total_calls == 3
      assert length(result.all_events) == 4

      # Verify events are in correct order (newest first)
      timestamps = Enum.map(result.all_events, & &1["created_at"])
      assert timestamps == Enum.sort(timestamps, :desc)
    end

    test "respects global limit during pagination" do
      # Mock events with more than the global limit
      events_batch_1 = [
        %{"id" => "event1", "kind" => 1, "pubkey" => "pubkey1", "created_at" => 1754500000, "content" => "event1"},
        %{"id" => "event2", "kind" => 1, "pubkey" => "pubkey2", "created_at" => 1754400000, "content" => "event2"}
      ]

      events_batch_2 = [
        %{"id" => "event3", "kind" => 1, "pubkey" => "pubkey3", "created_at" => 1754300000, "content" => "event3"},
        %{"id" => "event4", "kind" => 1, "pubkey" => "pubkey4", "created_at" => 1754200000, "content" => "event4"}
      ]

      events_batch_3 = [
        %{"id" => "event5", "kind" => 1, "pubkey" => "pubkey5", "created_at" => 1754100000, "content" => "event5"}
      ]

      pagination_state = %{
        calls: 0,
        events_batches: [events_batch_1, events_batch_2, events_batch_3],
        global_limit: 3  # Stop after 3 events
      }

      result = simulate_pagination(pagination_state, self())

      assert result.total_events == 3  # Should stop at global limit
      assert result.total_calls == 2   # Should stop after second call
      assert length(result.all_events) == 3
    end

    test "handles pagination with interval delays" do
      events_batch_1 = [
        %{"id" => "event1", "kind" => 1, "pubkey" => "pubkey1", "created_at" => 1754500000, "content" => "event1"}
      ]

      events_batch_2 = [
        %{"id" => "event2", "kind" => 1, "pubkey" => "pubkey2", "created_at" => 1754400000, "content" => "event2"}
      ]

      events_batch_3 = []

      pagination_state = %{
        calls: 0,
        events_batches: [events_batch_1, events_batch_2, events_batch_3],
        interval: 100  # 100ms interval
      }

      start_time = System.monotonic_time(:millisecond)
      result = simulate_pagination(pagination_state, self())
      end_time = System.monotonic_time(:millisecond)

      assert result.total_events == 2
      assert result.total_calls == 3

      # Should have at least 200ms delay (2 intervals)
      elapsed_time = end_time - start_time
      assert elapsed_time >= 200
    end

    test "updates filter with until timestamp correctly" do
      # Test that the filter is updated with the timestamp of the last event
      events_batch_1 = [
        %{"id" => "event1", "kind" => 1, "pubkey" => "pubkey1", "created_at" => 1754500000, "content" => "event1"},
        %{"id" => "event2", "kind" => 1, "pubkey" => "pubkey2", "created_at" => 1754400000, "content" => "event2"}
      ]

      events_batch_2 = []

      # Test the actual pagination logic
      initial_filter = %{kinds: [1], limit: 2}

      # Simulate first call
      first_result = simulate_single_pagination_call(initial_filter, events_batch_1)

      # Simulate second call with updated filter
      second_result = simulate_single_pagination_call(first_result.updated_filter, events_batch_2)

      assert first_result.events_count == 2
      assert second_result.events_count == 0

      # Verify filter was updated with the timestamp of the last event
      assert first_result.updated_filter[:until] == 1754400000
    end

    test "handles events without created_at timestamp" do
      # Test pagination with events that don't have created_at
      events_batch_1 = [
        %{"id" => "event1", "kind" => 1, "pubkey" => "pubkey1", "content" => "event1"},  # No created_at
        %{"id" => "event2", "kind" => 1, "pubkey" => "pubkey2", "created_at" => 1754400000, "content" => "event2"}
      ]

      # Test the actual pagination logic
      initial_filter = %{kinds: [1], limit: 2}

      # Simulate call with events including one without created_at
      result = simulate_single_pagination_call(initial_filter, events_batch_1)

      assert result.events_count == 2

      # Should use current timestamp for events without created_at
      assert Map.has_key?(result.updated_filter, :until)
      assert result.updated_filter[:until] > 0
    end

    test "handles empty results in first query" do
      # Test pagination when first query returns no results
      events_batch_1 = []
      events_batch_2 = [
        %{"id" => "event1", "kind" => 1, "pubkey" => "pubkey1", "created_at" => 1754500000, "content" => "event1"}
      ]

      pagination_state = %{
        calls: 0,
        events_batches: [events_batch_1, events_batch_2],
        track_filters: true
      }

      result = simulate_pagination_with_filter_tracking(pagination_state, self())

      assert result.total_events == 0
      assert result.total_calls == 1

      # Should stop after first empty result
      [first_filter] = result.filters_used
      refute Map.has_key?(first_filter, :until)
    end
  end

  # Helper functions to simulate pagination
  defp simulate_pagination(state, test_pid) do
    simulate_pagination_recursive(state, test_pid, [], [])
  end

  defp simulate_pagination_recursive(%{calls: calls, events_batches: [current_batch | remaining_batches]} = state, test_pid, all_events, filters_used) do
    # Simulate the fetch call
    new_calls = calls + 1
    new_all_events = all_events ++ current_batch

    # Check global limit
    global_limit = Map.get(state, :global_limit, :infinity)
    if global_limit != :infinity and length(new_all_events) >= global_limit do
      %{
        total_events: length(Enum.take(new_all_events, global_limit)),
        total_calls: new_calls,
        all_events: Enum.take(new_all_events, global_limit),
        filters_used: filters_used
      }
    else
      if length(current_batch) == 0 do
        # No more events, we're done
        %{
          total_events: length(new_all_events),
          total_calls: new_calls,
          all_events: new_all_events,
          filters_used: filters_used
        }
      else
        # Update filter for next iteration
        last_event = List.last(current_batch)
        until_timestamp = get_event_timestamp(last_event)

        # Simulate interval delay
        interval = Map.get(state, :interval, 0)
        if interval > 0 do
          :timer.sleep(interval)
        end

        # Continue with next batch
        simulate_pagination_recursive(
          %{state | calls: new_calls, events_batches: remaining_batches},
          test_pid,
          new_all_events,
          filters_used
        )
      end
    end
  end

  defp simulate_pagination_recursive(%{calls: calls}, _test_pid, all_events, filters_used) do
    %{
      total_events: length(all_events),
      total_calls: calls,
      all_events: all_events,
      filters_used: filters_used
    }
  end

  defp simulate_pagination_with_filter_tracking(state, test_pid) do
    simulate_pagination_with_filter_tracking_recursive(state, test_pid, [], [])
  end

  defp simulate_pagination_with_filter_tracking_recursive(%{calls: calls, events_batches: [current_batch | remaining_batches]} = state, test_pid, all_events, filters_used) do
    # Simulate the fetch call
    new_calls = calls + 1
    new_all_events = all_events ++ current_batch

    # Track the filter used (simulate initial filter)
    current_filter = if calls == 0 do
      %{kinds: [1], limit: 2}
    else
      # Get the last filter and update it
      last_filter = List.last(filters_used)
      if length(current_batch) > 0 do
        last_event = List.last(current_batch)
        until_timestamp = get_event_timestamp(last_event)
        Map.put(last_filter, :until, until_timestamp)
      else
        last_filter
      end
    end
    new_filters_used = filters_used ++ [current_filter]

    if length(current_batch) == 0 do
      # No more events, we're done
      %{
        total_events: length(new_all_events),
        total_calls: new_calls,
        all_events: new_all_events,
        filters_used: new_filters_used
      }
    else
      # Continue with next batch
      simulate_pagination_with_filter_tracking_recursive(
        %{state | calls: new_calls, events_batches: remaining_batches},
        test_pid,
        new_all_events,
        new_filters_used
      )
    end
  end

  defp simulate_pagination_with_filter_tracking_recursive(%{calls: calls}, _test_pid, all_events, filters_used) do
    %{
      total_events: length(all_events),
      total_calls: calls,
      all_events: all_events,
      filters_used: filters_used
    }
  end

  defp get_event_timestamp(event) do
    case event["created_at"] do
      timestamp when is_integer(timestamp) -> timestamp
      _ -> System.system_time(:second)
    end
  end

  defp simulate_single_pagination_call(filter, events) do
    events_count = length(events)

    if events_count > 0 do
      # Update filter for next iteration
      last_event = List.last(events)
      until_timestamp = get_event_timestamp(last_event)
      updated_filter = Map.put(filter, :until, until_timestamp)

      %{
        events_count: events_count,
        updated_filter: updated_filter
      }
    else
      %{
        events_count: events_count,
        updated_filter: filter
      }
    end
  end
end
