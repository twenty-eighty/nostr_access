defmodule Nostr.Publisher do
  @moduledoc """
  Manages publishing a single Nostr event across multiple relays and collecting OK acks.
  """

  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    defstruct [
      :event,
      :event_id,
      :caller,
      :min_ok,
      :overall_timer,
      relays: [],
      # relay_uri => :pending | {:ok, msg} | {:error, msg}
      relay_statuses: %{},
      # conn_pid => relay_uri
      connection_relays: %{},
      ok_count: 0
    ]
  end

  @type publish_result :: %{
          event_id: String.t() | nil,
          ok: non_neg_integer(),
          total: non_neg_integer(),
          statuses: %{optional(String.t()) => :pending | {:ok, String.t()} | {:error, String.t()}}
        }

  @spec start_link({[String.t()], map(), pid(), Keyword.t()}) :: {:ok, pid()} | {:error, term()}
  def start_link({relays, event, caller, opts}) do
    GenServer.start_link(__MODULE__, {relays, event, caller, opts})
  end

  @impl GenServer
  def init({relays, event, caller, opts}) do
    require Logger
    unique_relays = relays |> Enum.uniq() |> Enum.sort()

    min_ok = Keyword.get(opts, :min_ok, 1)
    overall_timeout = Keyword.get(opts, :overall_timeout, 30_000)
    overall_timer = Process.send_after(self(), :overall_timeout, overall_timeout)

    event_id = case event do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end

    state = %State{
      event: event,
      event_id: event_id,
      caller: caller,
      min_ok: min_ok,
      overall_timer: overall_timer,
      relays: unique_relays,
      relay_statuses: Map.new(unique_relays, fn r -> {r, :pending} end)
    }

    {:ok, start_publishes(state)}
  end

  @impl GenServer
  def handle_info({:pub_ack, conn_pid, _event_id, success?, msg}, state) do
    case Map.get(state.connection_relays, conn_pid) do
      relay when is_binary(relay) ->
        new_status = if success?, do: {:ok, msg}, else: {:error, msg}
        prev_status = Map.get(state.relay_statuses, relay)

        {ok_inc, relay_statuses} =
          case prev_status do
            :pending ->
              {if(success?, do: 1, else: 0), Map.put(state.relay_statuses, relay, new_status)}

            _ ->
              {0, state.relay_statuses}
          end

        new_ok = state.ok_count + ok_inc
        new_state = %{state | relay_statuses: relay_statuses, ok_count: new_ok}

        if new_ok >= state.min_ok or all_done?(new_state) do
          finish(new_state)
        else
          {:noreply, new_state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:connection_down, conn_pid, reason}, state) do
    case Map.get(state.connection_relays, conn_pid) do
      relay when is_binary(relay) ->
        Logger.warning("Connection down to #{relay}: #{inspect(reason)}")
        new_statuses =
          case Map.get(state.relay_statuses, relay) do
            :pending -> Map.put(state.relay_statuses, relay, {:error, inspect(reason)})
            other -> Map.put(state.relay_statuses, relay, other)
          end

        new_state = %{state | relay_statuses: new_statuses}
        if all_done?(new_state), do: finish(new_state), else: {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:overall_timeout, state) do
    Logger.warning("Publish overall timeout reached")
    finish(state)
  end

  defp start_publishes(state) do
    query_pid = self()

    results =
      Task.async_stream(
        state.relays,
        fn relay -> start_single_publish(relay, state.event, query_pid) end,
        timeout: 10_000
      )

    Enum.reduce(results, state, fn
      {:ok, {:ok, conn_pid, relay}}, acc_state ->
        new_map = Map.put(acc_state.connection_relays || %{}, conn_pid, relay)
        %{acc_state | connection_relays: new_map}

      {:ok, {:error, relay, reason}}, acc_state ->
        Logger.error("Failed to publish on #{relay}: #{inspect(reason)}")
        %{
          acc_state
          | relay_statuses: Map.put(acc_state.relay_statuses, relay, {:error, inspect(reason)})
        }

      {:exit, reason}, acc_state ->
        Logger.error("Task failed with reason: #{inspect(reason)}")
        acc_state
    end)
  end

  defp start_single_publish(relay, event, caller_pid) do
    case start_relay_pool(relay) do
      {:ok, pool_pid} ->
        case Nostr.RelayPool.checkout_conn(pool_pid) do
          {:ok, conn_pid} ->
            # Send publish request directly to connection
            send(conn_pid, {:publish_event, caller_pid, event})
            {:ok, conn_pid, relay}

          {:error, :no_slot} ->
            {:error, relay, :no_slot}

          {:error, {:connection_failed, reason}} ->
            {:error, relay, {:connection_failed, reason}}
        end

      {:error, reason} ->
        {:error, relay, reason}
    end
  end

  defp finish(state) do
    cancel_timer(state.overall_timer)

    result = %{
      event_id: state.event_id,
      ok: state.ok_count,
      total: length(state.relays),
      statuses: state.relay_statuses
    }

    if state.ok_count >= state.min_ok do
      send_result(state.caller, {:ok, result})
    else
      send_result(state.caller, {:error, {:min_ok_not_met, result}})
    end

    {:stop, :normal, state}
  end

  defp all_done?(state) do
    Enum.all?(state.relay_statuses, fn {_relay, status} -> status != :pending end)
  end

  defp send_result(caller, result) do
    case caller do
      {pid, ref} when is_pid(pid) -> send(pid, {ref, result})
      pid when is_pid(pid) -> send(pid, result)
    end
  end

  defp start_relay_pool(relay) do
    case Registry.lookup(Registry.NostrRelayPools, {Nostr.RelayPool, relay}) do
      [{pid, _}] -> {:ok, pid}
      [] ->
        child_spec = %{
          id: {Nostr.RelayPool, relay},
          start: {Nostr.RelayPool, :start_link, [relay]},
          restart: :permanent,
          shutdown: 5000,
          type: :worker
        }

        case DynamicSupervisor.start_child(DynamicSupervisor.RelayPoolSup, child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end
