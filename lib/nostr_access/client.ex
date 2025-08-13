defmodule Nostr.Client do
  @moduledoc """
  Public API for querying Nostr relays.
  """

  @type relay_uri :: String.t()
  @type filter :: map()
  @type event :: map()
  @type query_ref :: reference()

  @doc """
  Fetches events from the specified relays using the given filter.

  This is a blocking call that waits for either:
  - EOSE from every relay, or
  - idle timeout (default: 500ms)

  ## Options

  - `:idle_ms` - inactivity window in milliseconds (default: 500)
  - `:overall_timeout` - hard stop timeout in milliseconds (default: 30_000)
  - `:cache?` - enable/disable caching (default: true)
  - `:dedup_strategy` - deduplication strategy module (default: Nostr.Dedup.Default)
  - `:paginate` - when true, perform repeated queries decreasing `:until` until no more events are returned or global limit reached (default: false)
  - `:paginate_global_limit` - total number of events to return across all pages; defaults to `filter[:limit]` or `:infinity`
  - `:paginate_interval` - delay in milliseconds between pages (default: 0)
  - `:paginate_early_stop_threshold` - when a page returns fewer events than this value, stop paginating (default: 100)

  ## Examples

      iex> Nostr.Client.fetch(["wss://relay.example.com"], %{kinds: [1]})
      {:ok, [%{"id" => "event_id", "kind" => 1, ...}]}

      iex> Nostr.Client.fetch(["wss://relay1.com", "wss://relay2.com"], %{authors: ["pubkey"]}, idle_ms: 1000)
      {:ok, [%{"id" => "event_id", "pubkey" => "pubkey", ...}]}
  """
  @spec fetch([relay_uri], filter, Keyword.t()) :: {:ok, [event]} | {:error, term()}
  def fetch(relays, filter, opts \\ []) do
    with {:ok, canonical_filter} <- validate_filter(filter) do
      if Keyword.get(opts, :paginate, false) do
        fetch_paginated_canonical(relays, canonical_filter, opts)
      else
        fetch_once_canonical(relays, canonical_filter, opts)
      end
    end
  end

  @doc """
  Starts a streaming query to the specified relays using the given filter.

  This is a non-blocking call that returns immediately with a query reference.
  The caller receives messages:
  - `{:nostr_event, query_ref, event}` - when a new event arrives
  - `{:nostr_eose, query_ref, done?}` - when a relay sends EOSE (done? is true if all relays are done)

  ## Options

  Same options as `fetch/3`.

  ## Examples

      iex> {:ok, ref} = Nostr.Client.stream(["wss://relay.example.com"], %{kinds: [1]})
      iex> receive do
      ...>   {:nostr_event, ^ref, event} -> event
      ...>   {:nostr_eose, ^ref, true} -> :done
      ...> end
  """
  @spec stream([relay_uri], filter, Keyword.t()) :: {:ok, query_ref} | {:error, term()}
  def stream(relays, filter, opts \\ []) do
    with {:ok, canonical_filter} <- validate_filter(filter),
         {:ok, query_pid} <- start_query(relays, canonical_filter, {self(), make_ref()}, opts) do
      {:ok, query_pid}
    end
  end

  @doc """
  Cancels a streaming query.

  ## Examples

      iex> {:ok, ref} = Nostr.Client.stream(["wss://relay.example.com"], %{kinds: [1]})
      iex> Nostr.Client.cancel(ref)
      :ok
  """
  @spec cancel(query_ref) :: :ok | {:error, :not_found}
  def cancel(query_ref) when is_pid(query_ref) do
    if Process.alive?(query_ref) do
      Nostr.Query.cancel(query_ref)
      :ok
    else
      {:error, :not_found}
    end
  end

  def cancel(_query_ref) do
    {:error, :not_found}
  end

  defp validate_filter(filter) do
    try do
      canonical_filter = Nostr.Filter.validate!(filter)
      {:ok, canonical_filter}
    rescue
      e in ArgumentError -> {:error, e.message}
    end
  end

  # Performs a single query using a canonical filter
  defp fetch_once_canonical(relays, canonical_filter, opts) do
    with {:ok, query_pid} <- start_query(relays, canonical_filter, self(), opts) do
      receive do
        {:ok, events} -> {:ok, events}
        {:error, reason} -> {:error, reason}
      after
        Keyword.get(opts, :overall_timeout, 30_000) ->
          Nostr.Query.cancel(query_pid)
          {:error, :timeout}
      end
    end
  end

  # Paginates by repeatedly decreasing :until and accumulating results
  defp fetch_paginated_canonical(relays, canonical_filter, opts) do
    global_limit =
      Keyword.get(opts, :paginate_global_limit) || Map.get(canonical_filter, :limit) || :infinity

    interval_ms = Keyword.get(opts, :paginate_interval, 0)

    do_fetch_pages(relays, canonical_filter, opts, global_limit, interval_ms, [])
  end

  defp do_fetch_pages(relays, canonical_filter, opts, global_limit, interval_ms, acc_events) do
    # Disable cache between pages to avoid stale overlaps
    opts_no_cache = Keyword.put(opts, :cache?, false)

    case fetch_once_canonical(relays, canonical_filter, opts_no_cache) do
      {:ok, events} ->
        new_acc = acc_events ++ events

        early_stop_threshold = Keyword.get(opts, :paginate_early_stop_threshold, 100)

        cond do
          # Early stop: fewer than threshold means likely last page
          length(events) < early_stop_threshold ->
            {:ok,
             finalize_paginated(new_acc, Map.get(canonical_filter, :limit), global_limit, opts)}

          # Global cap reached
          global_limit != :infinity and length(new_acc) >= global_limit ->
            {:ok,
             finalize_paginated(new_acc, Map.get(canonical_filter, :limit), global_limit, opts)}

          true ->
            # Advance window using minimum created_at from this page
            min_ts =
              Enum.reduce(events, nil, fn ev, acc ->
                ts = get_event_timestamp(ev)

                cond do
                  is_nil(acc) -> ts
                  ts < acc -> ts
                  true -> acc
                end
              end)

            next_until = max((min_ts || System.system_time(:second)) - 1, 0)

            # Stop if we crossed since boundary or until didn't move
            since_boundary = Map.get(canonical_filter, :since)
            prev_until = Map.get(canonical_filter, :until)

            cond do
              is_integer(since_boundary) and next_until <= since_boundary ->
                {:ok,
                 finalize_paginated(
                   new_acc,
                   Map.get(canonical_filter, :limit),
                   global_limit,
                   opts
                 )}

              prev_until == next_until ->
                {:ok,
                 finalize_paginated(
                   new_acc,
                   Map.get(canonical_filter, :limit),
                   global_limit,
                   opts
                 )}

              true ->
                next_filter = Map.put(canonical_filter, :until, next_until)

                if interval_ms > 0 do
                  :timer.sleep(interval_ms)
                end

                do_fetch_pages(relays, next_filter, opts, global_limit, interval_ms, new_acc)
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_paginated(events, _per_page_limit, global_limit, opts) do
    # Dedup across all collected events then apply global limit
    dedup_strategy = Keyword.get(opts, :dedup_strategy, Nostr.Dedup.Default)
    deduped = dedup_strategy.dedup(events, %{})

    final =
      if global_limit != :infinity do
        Enum.take(deduped, global_limit)
      else
        deduped
      end

    final
  end

  defp get_event_timestamp(event) do
    case event["created_at"] do
      ts when is_integer(ts) -> ts
      _ -> System.system_time(:second)
    end
  end

  defp start_query(relays, canonical_filter, caller, opts) do
    require Logger
    Logger.info("Starting query for relays: #{inspect(relays)}")

    child_spec = %{
      id: Nostr.Query,
      start: {Nostr.Query, :start_link, [{relays, canonical_filter, caller, opts}]},
      restart: :temporary,
      shutdown: 5000,
      type: :worker
    }

    case DynamicSupervisor.start_child(DynamicSupervisor.QuerySup, child_spec) do
      {:ok, query_pid} ->
        Logger.info("Query started successfully: #{inspect(query_pid)}")
        {:ok, query_pid}

      {:error, reason} ->
        Logger.error("Failed to start query: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
