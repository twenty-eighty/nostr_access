defmodule Nostr.Query do
  @moduledoc """
  Manages a single query request across multiple relays.
  """

  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    defstruct [
      :query_ref,
      :relays,
      :canonical_filter,
      :caller,
      :opts,
      :cache_key,
      events: [],
      # relay_uri => :pending | :eose | :error
      relay_states: %{},
      # conn_pid => sub_id
      connections: %{},
      # conn_pid => relay_uri
      connection_relays: %{},
      idle_timer: nil,
      overall_timer: nil
    ]
  end

  @doc """
  Starts a new query.
  """
  @spec start_link({[String.t()], map(), pid(), Keyword.t()}) :: {:ok, pid()} | {:error, term()}
  def start_link({relays, canonical_filter, caller, opts}) do
    GenServer.start_link(__MODULE__, {relays, canonical_filter, caller, opts})
  end

  @doc """
  Cancels a query.
  """
  @spec cancel(pid()) :: :ok
  def cancel(query_pid) do
    GenServer.cast(query_pid, :cancel)
  end

  @impl GenServer
  def init({relays, canonical_filter, caller, opts}) do
    # Deduplicate and sort relays
    unique_relays = relays |> Enum.uniq() |> Enum.sort()

    # Create cache key
    cache_key = Nostr.Cache.make_key(unique_relays, canonical_filter)

    # Set up timers
    # Increased from 500ms to 5s
    idle_ms = Keyword.get(opts, :idle_ms, 5000)
    overall_timeout = Keyword.get(opts, :overall_timeout, 30_000)

    idle_timer = Process.send_after(self(), :idle_timeout, idle_ms)
    overall_timer = Process.send_after(self(), :overall_timeout, overall_timeout)

    state = %State{
      query_ref: make_ref(),
      relays: unique_relays,
      canonical_filter: canonical_filter,
      caller: caller,
      opts: opts,
      cache_key: cache_key,
      relay_states: Map.new(unique_relays, fn relay -> {relay, :pending} end),
      connection_relays: %{},
      idle_timer: idle_timer,
      overall_timer: overall_timer
    }

    # Check cache first
    case check_cache(state) do
      {:ok, cached_events} ->
        # Cache hit, return immediately
        send_result(caller, {:ok, cached_events})
        # Return ok state but send stop message to self
        Process.send_after(self(), :stop_after_cache_hit, 0)
        {:ok, state}

      {:miss, []} ->
        # Cache miss, proceed with query
        {:ok, start_relay_queries(state)}

      {:error, _reason} ->
        # Cache error, proceed with query
        {:ok, start_relay_queries(state)}
    end
  end

  @impl GenServer
  def handle_info({:event, _conn_pid, _sub_id, event}, state) do
    require Logger
    Logger.info("Received event: #{inspect(event)}")

    # Reset idle timer
    cancel_timer(state.idle_timer)

    idle_timer =
      Process.send_after(self(), :idle_timeout, Keyword.get(state.opts, :idle_ms, 5000))

    # Add event to collection
    new_state = %{state | events: [event | state.events], idle_timer: idle_timer}

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:eose, conn_pid, sub_id}, state) do
    # Find which relay this connection belongs to
    case find_relay_for_connection(conn_pid, state) do
      {:ok, relay} ->
        # Proactively close the subscription on the relay to avoid counting toward REQ limits
        Nostr.Connection.close_subscription(conn_pid, sub_id)

        new_relay_states = Map.put(state.relay_states, relay, :eose)
        new_state = %{state | relay_states: new_relay_states}

        # Free a slot on the pool by checking the connection back in, if we know the pool
        case Map.get(state.connection_relays, conn_pid) do
          relay when is_binary(relay) ->
            case Registry.lookup(Registry.NostrRelayPools, {Nostr.RelayPool, relay}) do
              [{pool_pid, _}] -> Nostr.RelayPool.checkin_conn(pool_pid, conn_pid)
              _ -> :ok
            end

          _ ->
            :ok
        end

        # Check if all relays have sent EOSE
        if all_relays_eose?(new_state) do
          finish_query(new_state)
        else
          {:noreply, new_state}
        end

      _ ->
        # Unknown connection, ignore
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:idle_timeout, state) do
    require Logger
    Logger.info("Idle timeout reached, finishing query with #{length(state.events)} events")
    # Idle timeout reached, finish query
    finish_query(state)
  end

  @impl GenServer
  def handle_info(:overall_timeout, state) do
    # Overall timeout reached, finish query
    Logger.warning("Query overall timeout reached")
    finish_query(state)
  end

  @impl GenServer
  def handle_info(:stop_after_cache_hit, state) do
    # Stop after cache hit
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({:connection_down, _conn_pid, reason}, state) do
    # Connection died, mark relay as error
    # This is simplified - in a real implementation you'd track which relay
    # each connection belongs to
    Logger.warning("Connection down: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(:cancel, state) do
    Logger.info("Query cancelled")
    send_result(state.caller, {:error, :cancelled})
    {:stop, :normal, state}
  end

  defp check_cache(state) do
    cache? = Keyword.get(state.opts, :cache?, true)

    if cache? do
      # Try the appropriate cache based on filter
      case Nostr.Cache.get_events(state.cache_key, state.canonical_filter) do
        {:ok, events} when is_list(events) and length(events) > 0 ->
          {:ok, events}

        {:ok, []} ->
          # Zero results found
          {:miss, []}

        _ ->
          # Try zero results cache as fallback
          case Nostr.Cache.get_zero_results(state.cache_key) do
            # Explicit zero-results entry present
            {:ok, []} -> {:miss, []}
            # No zero-results entry (nil) should not be treated as a hit
            {:ok, nil} -> {:error, :not_found}
            # Any other unexpected return is a cache error
            _ -> {:error, :cache_error}
          end
      end
    else
      {:error, :cache_disabled}
    end
  end

  defp start_relay_queries(state) do
    require Logger
    Logger.info("Starting relay queries for relays: #{inspect(state.relays)}")

    # Start relay pools and send queries simultaneously
    query_pid = self()

    results =
      Task.async_stream(
        state.relays,
        fn relay -> start_single_relay_query(relay, state.canonical_filter, query_pid) end,
        timeout: 10_000
      )

    # Process results and update state
    new_state =
      Enum.reduce(results, state, fn
        {:ok, {:ok, conn_pid, sub_id, relay}}, acc_state ->
          new_connections = Map.put(acc_state.connections || %{}, conn_pid, sub_id)
          new_connection_relays = Map.put(acc_state.connection_relays || %{}, conn_pid, relay)
          %{acc_state | connections: new_connections, connection_relays: new_connection_relays}

        {:ok,
         {:error, relay,
          {:connection_failed, %WebSockex.RequestError{code: 302, message: "Found"}}}},
        acc_state ->
          Logger.error("Relay #{relay} is not a valid WebSocket endpoint (HTTP 302 redirect)")
          new_relay_states = Map.put(acc_state.relay_states, relay, :error)
          %{acc_state | relay_states: new_relay_states}

        {:ok, {:error, relay, {:connection_failed, reason}}}, acc_state ->
          Logger.error("Connection failed for relay #{relay}: #{inspect(reason)}")
          new_relay_states = Map.put(acc_state.relay_states, relay, :error)
          %{acc_state | relay_states: new_relay_states}

        {:ok, {:error, relay, reason}}, acc_state ->
          Logger.error("Failed to start relay query for #{relay}: #{inspect(reason)}")
          new_relay_states = Map.put(acc_state.relay_states, relay, :error)
          %{acc_state | relay_states: new_relay_states}

        {:exit, reason}, acc_state ->
          Logger.error("Task failed with reason: #{inspect(reason)}")
          acc_state
      end)

    Logger.info("Finished starting relay queries")
    new_state
  end

  defp start_single_relay_query(relay, canonical_filter, query_pid) do
    case start_relay_pool(relay) do
      {:ok, pool_pid} ->
        case Nostr.RelayPool.checkout_conn(pool_pid) do
          {:ok, conn_pid} ->
            sub_id = generate_sub_id()

            Logger.info(
              "Sending filter to connection #{inspect(conn_pid)} with sub_id: #{sub_id}"
            )

            # Send filter directly to connection, bypassing relay pool for message handling
            send(conn_pid, {:send_filter, query_pid, sub_id, canonical_filter})
            {:ok, conn_pid, sub_id, relay}

          {:error, :no_slot} ->
            Logger.warning("No slots available for relay: #{relay}")
            {:error, relay, :no_slot}

          {:error, {:connection_failed, reason}} ->
            Logger.error("Connection failed for relay #{relay}: #{inspect(reason)}")
            {:error, relay, {:connection_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("Failed to start relay pool for #{relay}: #{inspect(reason)}")
        {:error, relay, reason}
    end
  end

  defp finish_query(state) do
    require Logger
    Logger.info("Finishing query with #{length(state.events)} events")

    # Cancel timers
    cancel_timer(state.idle_timer)
    cancel_timer(state.overall_timer)

    # Close any open subscriptions to avoid server-side REQ accumulation
    Enum.each(state.connections, fn {conn_pid, sub_id} ->
      Nostr.Connection.close_subscription(conn_pid, sub_id)
    end)

    # Deduplicate events (without limit)
    dedup_strategy = Keyword.get(state.opts, :dedup_strategy, Nostr.Dedup.Default)
    filter_without_limit = Map.delete(state.canonical_filter, :limit)
    deduped_events = dedup_strategy.dedup(state.events, filter_without_limit)

    # Apply limit after deduplication
    final_events =
      case Map.get(state.canonical_filter, :limit) do
        limit when is_integer(limit) and limit > 0 ->
          Enum.take(deduped_events, limit)

        _ ->
          deduped_events
      end

    # Cache result
    cache_result(state, final_events)

    # Send result to caller
    send_result(state.caller, {:ok, final_events})

    Logger.info("Query process stopping normally")
    {:stop, :normal, state}
  end

  defp cache_result(state, events) do
    cache? = Keyword.get(state.opts, :cache?, true)

    if cache? do
      if length(events) > 0 do
        Nostr.Cache.put_events(state.cache_key, events, state.canonical_filter)
      else
        Nostr.Cache.put_zero_results(state.cache_key, [])
      end
    end
  end

  defp send_result(caller, result) do
    case caller do
      {pid, ref} when is_pid(pid) ->
        send(pid, {ref, result})

      pid when is_pid(pid) ->
        send(pid, result)
    end
  end

  defp start_relay_pool(relay) do
    # Use a process-level lock to prevent race conditions in relay pool creation
    lock_name = {:relay_pool_lock, relay}

    # Try to acquire the lock
    case :ets.lookup(:relay_pool_locks, lock_name) do
      [] ->
        # No lock exists, create one and proceed
        :ets.insert(:relay_pool_locks, {lock_name, self()})

        # Double-check the registry after acquiring the lock
        case Registry.lookup(Registry.NostrRelayPools, {Nostr.RelayPool, relay}) do
          [{pid, _}] ->
            :ets.delete(:relay_pool_locks, lock_name)
            {:ok, pid}

          [] ->
            # Create a unique child spec for this relay
            child_spec = %{
              id: {Nostr.RelayPool, relay},
              start: {Nostr.RelayPool, :start_link, [relay]},
              restart: :permanent,
              shutdown: 5000,
              type: :worker
            }

            case DynamicSupervisor.start_child(DynamicSupervisor.RelayPoolSup, child_spec) do
              {:ok, pid} ->
                :ets.delete(:relay_pool_locks, lock_name)
                {:ok, pid}

              {:error, {:already_started, pid}} ->
                :ets.delete(:relay_pool_locks, lock_name)
                {:ok, pid}

              {:error, reason} ->
                :ets.delete(:relay_pool_locks, lock_name)
                {:error, reason}
            end
        end

      [{^lock_name, _owner_pid}] ->
        # Lock exists, wait a bit and try again
        Process.sleep(10)
        start_relay_pool(relay)
    end
  end

  defp find_relay_for_connection(conn_pid, state) do
    case Map.get(state.connection_relays, conn_pid) do
      relay when is_binary(relay) -> {:ok, relay}
      nil -> :error
    end
  end

  defp all_relays_eose?(state) do
    Enum.all?(state.relay_states, fn {_relay, status} ->
      status == :eose or status == :error
    end)
  end

  defp generate_sub_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end
