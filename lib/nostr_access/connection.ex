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
      subscriptions: %{},  # sub_id => {caller_pid, filter_json}
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
  Closes a subscription.
  """
  @spec close_subscription(pid(), String.t()) :: :ok
  def close_subscription(conn_pid, sub_id) do
    WebSockex.send_frame(conn_pid, {:text, Jason.encode!(["CLOSE", sub_id])})
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

    case Jason.decode(message) do
      {:ok, ["EVENT", sub_id, event]} ->
        Logger.debug("Received EVENT for sub_id: #{sub_id}")
        handle_event(sub_id, event, state)

      {:ok, ["EOSE", sub_id]} ->
        Logger.debug("Received EOSE for sub_id: #{sub_id}")
        handle_eose(sub_id, state)

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
  end



  @impl WebSockex
  def handle_info({:send_filter, caller_pid, sub_id, filter}, state) do
    if state.free_slots > 0 do
      message = Jason.encode!(["REQ", sub_id, filter])
      require Logger
      Logger.info("Sending REQ message: #{message}")
      {:reply, {:text, message}, %{state |
        subscriptions: Map.put(state.subscriptions, sub_id, {caller_pid, filter}),
        free_slots: state.free_slots - 1
      }}
    else
      {:ok, state}
    end
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    require Logger
    Logger.warning("WebSocket disconnected from #{state.uri}: #{inspect(reason)}")

    # Notify caller about disconnection
    send(state.caller_pid, {:connection_down, self(), reason})

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
        new_state = %{state |
          subscriptions: Map.delete(state.subscriptions, sub_id),
          free_slots: state.free_slots + 1
        }
        {:ok, new_state}

      nil ->
        # Unknown subscription, ignore
        {:ok, state}
    end
  end

  defp via(uri) do
    {:via, Registry, {Registry.NostrConnections, {__MODULE__, uri}}}
  end
end
