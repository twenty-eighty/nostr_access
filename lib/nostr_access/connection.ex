defmodule Nostr.Connection do
  @moduledoc """
  WebSocket connection to a Nostr relay with subscription management.
  """

  use WebSockex

  defmodule State do
    @moduledoc false
    defstruct [
      :uri,
      :caller_pid,
      # sub_id => {caller_pid, filter_json}
      subscriptions: %{},
      # event_id => caller_pid (for publish acks)
      publishes: %{},
      free_slots: 10
    ]
  end

  @doc """
  Starts a new connection to a relay.
  """
  @spec start_link(String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_link(uri, caller_pid) do
    WebSockex.start_link(uri, __MODULE__, {uri, caller_pid}, name: via(uri))
  end

  @impl WebSockex
  def handle_connect(_conn, {uri, caller_pid}) do
    require Logger
    Logger.info("WebSocket connected to relay: #{uri}")
    {:ok, %State{uri: uri, caller_pid: caller_pid}}
  end

  @impl WebSockex
  def terminate(reason, _state) do
    require Logger
    Logger.warning("WebSocket connection terminated: #{inspect(reason)}")
    :ok
  end

  @doc """
  Sends a filter to the relay.
  """
  @spec send_filter(pid(), pid(), String.t(), map()) :: :ok | {:error, :no_slots}
  def send_filter(conn_pid, caller_pid, sub_id, filter) do
    send(conn_pid, {:send_filter, caller_pid, sub_id, filter})
  end

  @doc """
  Publishes a Nostr event to the relay.
  The caller will receive `{:pub_ack, conn_pid, event_id, success?, message}`.
  """
  @spec publish_event(pid(), pid(), map()) :: :ok
  def publish_event(conn_pid, caller_pid, event) do
    send(conn_pid, {:publish_event, caller_pid, event})
  end

  @doc """
  Closes a subscription.
  """
  @spec close_subscription(pid(), String.t()) :: :ok
  def close_subscription(conn_pid, sub_id) do
    if Process.alive?(conn_pid) do
      try do
        WebSockex.send_frame(conn_pid, {:text, Jason.encode!(["CLOSE", sub_id])})
        :ok
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  @doc """
  Checks if the connection has free slots.
  """
  @spec has_free_slot?(pid()) :: boolean()
  def has_free_slot?(_conn_pid) do
    # WebSockex doesn't support GenServer.call, so we'll use a different approach
    # For now, we'll assume the connection has free slots
    true
  end

  @impl WebSockex
  def handle_frame({:text, message}, state) do
    require Logger
    Logger.debug("Received message from #{state.uri}: #{message}")

    try do
      case Jason.decode(message) do
        {:ok, ["EVENT", sub_id, event]} ->
          Logger.debug("Received EVENT for sub_id: #{sub_id}")
          handle_event(sub_id, event, state)

        {:ok, ["EOSE", sub_id]} ->
          Logger.debug("Received EOSE for sub_id: #{sub_id}")
          handle_eose(sub_id, state)

        {:ok, ["OK", event_id, success, msg]} ->
          # Relay acknowledgment for a published event
          handle_ok_ack(event_id, success, msg, state)

        {:ok, ["NOTICE", message]} ->
          # Log notice messages
          Logger.info("Relay notice from #{state.uri}: #{message}")
          {:ok, state}

        {:ok, other} ->
          # Log other message types
          Logger.debug("Received other message: #{inspect(other)}")
          {:ok, state}

        {:error, error} ->
          # Log malformed JSON
          Logger.warning("Malformed JSON from #{state.uri}: #{inspect(error)}")
          {:ok, state}
      end
    rescue
      exception ->
        Logger.error("Error processing frame from #{state.uri}: #{Exception.message(exception)}")
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_info({:send_filter, caller_pid, sub_id, filter}, state) do
    if state.free_slots > 0 do
      message = Jason.encode!(["REQ", sub_id, filter])
      require Logger
      Logger.info("Sending REQ message: #{message}")

      {:reply, {:text, message},
       %{
         state
         | subscriptions: Map.put(state.subscriptions, sub_id, {caller_pid, filter}),
           free_slots: state.free_slots - 1
       }}
    else
      {:ok, state}
    end
  end

  @impl WebSockex
  def handle_info({:publish_event, caller_pid, event}, state) do
    case event do
      %{"id" => event_id} when is_binary(event_id) ->
        message = Jason.encode!(["EVENT", event])
        require Logger
        Logger.info("Publishing EVENT to #{state.uri}: #{event_id}")

        {:reply, {:text, message},
         %{state | publishes: Map.put(state.publishes, event_id, caller_pid)}}

      _ ->
        # Event must include an id per NIP-01
        send(caller_pid, {:pub_ack, self(), nil, false, "invalid event: missing id"})
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_disconnect(disconnect_info, state) do
    require Logger
    Logger.warning("WebSocket disconnected from #{state.uri}: #{inspect(disconnect_info)}")

    # Notify caller about disconnection
    send(state.caller_pid, {:connection_down, self(), disconnect_info})

    {:reconnect, state}
  end

  defp handle_event(sub_id, event, state) do
    case Map.get(state.subscriptions, sub_id) do
      {caller_pid, _filter_json} ->
        send(caller_pid, {:event, self(), sub_id, event})
        {:ok, state}

      nil ->
        # Unknown subscription, ignore
        {:ok, state}
    end
  end

  defp handle_eose(sub_id, state) do
    case Map.get(state.subscriptions, sub_id) do
      {caller_pid, _filter_json} ->
        send(caller_pid, {:eose, self(), sub_id})

        # Free up the slot
        new_state = %{
          state
          | subscriptions: Map.delete(state.subscriptions, sub_id),
            free_slots: state.free_slots + 1
        }

        {:ok, new_state}

      nil ->
        # Unknown subscription, ignore
        {:ok, state}
    end
  end

  defp handle_ok_ack(event_id, success, msg, state) do
    case Map.get(state.publishes, event_id) do
      caller when is_pid(caller) ->
        send(caller, {:pub_ack, self(), event_id, success in [true, "true"], msg})
        # We keep the mapping to allow multiple OKs, but most relays send one
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  defp via(uri) do
    {:via, Registry, {Registry.NostrConnections, {__MODULE__, uri}}}
  end
end
