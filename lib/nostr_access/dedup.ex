defmodule Nostr.Dedup do
  @moduledoc """
  Behaviour for event deduplication strategies.
  """

  @callback dedup([map()], map()) :: [map()]

  @doc """
  Deduplicates events based on the filter type.
  """
  @spec dedup([map()], map()) :: [map()]
  def dedup(events, filter) do
    strategy = Application.get_env(:nostr_access, :dedup_strategy, Nostr.Dedup.Default)
    strategy.dedup(events, filter)
  end
end

defmodule Nostr.Dedup.Default do
  @moduledoc """
  Default deduplication strategy following NIP-01 rules.
  """

  @behaviour Nostr.Dedup

  @impl true
  def dedup(events, _filter) do
    # Sort events by created_at timestamp (newest first) before deduplication
    sorted_events = Enum.sort_by(events, &get_event_timestamp/1, :desc)

    # Take the first (newest) event from each group and maintain the sorted order
    sorted_events
    |> Enum.reduce([], fn event, acc ->
      key = uniqueness_key(event)
      if Enum.any?(acc, fn existing -> uniqueness_key(existing) == key end) do
        acc
      else
        [event | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp get_event_timestamp(event) do
    case event["created_at"] do
      timestamp when is_integer(timestamp) -> timestamp
      _ -> 0  # Default to 0 for events without timestamp
    end
  end

  defp uniqueness_key(event) do
    kind = event["kind"]

    cond do
      # Addressable events (kind 30000-39999)
      is_integer(kind) and kind >= 30000 and kind <= 39999 ->
        {kind, event["pubkey"], get_d_tag(event)}

      # Lists & Metadata (kind 0, 10000-19999)
      is_integer(kind) and (kind == 0 or (kind >= 10000 and kind <= 19999)) ->
        {kind, event["pubkey"]}

      # All other kinds
      true ->
        event["id"]
    end
  end

  defp get_d_tag(event) do
    case event["tags"] do
      tags when is_list(tags) ->
        Enum.find_value(tags, fn
          ["d", value | _] -> value
          _ -> nil
        end)

      _ ->
        nil
    end
  end
end
