defmodule Nostr.RelayPool do
  @moduledoc """
  Manages a pool of connections to a single relay.
  """

  use GenServer
  require Logger

  @max_connections 3

  defmodule State do
    @moduledoc false
    defstruct [
      :uri,
      connections: %{},  # pid() => free_slots :: 0..10
      waiting: [],       # [{caller_pid, ref}]
      creating_connection: false  # Flag to prevent duplicate connection creation
    ]
  end

  @doc """
  Starts a relay pool for the given URI.
  """
  @spec start_link(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(uri) do
    GenServer.start_link(__MODULE__, uri, name: via(uri))
  end

  @doc """
  Checks out a connection with a free slot.
  """
  @spec checkout_conn(pid()) :: {:ok, pid()} | {:error, :no_slot} | {:error, {:connection_failed, term()}}
  def checkout_conn(pool_pid) do
    GenServer.call(pool_pid, :checkout_conn, :infinity)
  end

  @doc """
  Checks in a connection after use.
  """
  @spec checkin_conn(pid(), pid()) :: :ok
  def checkin_conn(pool_pid, conn_pid) do
    GenServer.cast(pool_pid, {:checkin_conn, conn_pid})
  end

  @impl GenServer
  def init(uri) do
    {:ok, %State{uri: uri}}
  end

  @impl GenServer
  def handle_call(:checkout_conn, {caller_pid, _ref}, state) do
    case find_available_connection(state) do
      {:ok, conn_pid} ->
        # Decrement free slots
        new_connections = Map.update!(state.connections, conn_pid, &(&1 - 1))
        {:reply, {:ok, conn_pid}, %{state | connections: new_connections}}

      {:error, :no_slot} when map_size(state.connections) < @max_connections ->
        # Check if we're already creating a connection to prevent duplicates
        if Map.get(state, :creating_connection, false) do
          # Wait a bit and try again
          Process.sleep(50)
          GenServer.call(self(), :checkout_conn, 5000)
        else
          # Mark that we're creating a connection
          state = %{state | creating_connection: true}

          # Start a new connection with the query process as caller_pid
          case start_new_connection(state.uri, caller_pid) do
            {:ok, conn_pid} ->
              new_connections = Map.put(state.connections, conn_pid, 9)  # 10 - 1
              {:reply, {:ok, conn_pid}, %{state | connections: new_connections, creating_connection: false}}

            {:error, reason} ->
              Logger.error("Failed to start connection to #{state.uri}: #{inspect(reason)}")
              {:reply, {:error, {:connection_failed, reason}}, %{state | creating_connection: false}}
          end
        end

      {:error, :no_slot} ->
        # No slots available and at max connections
        {:reply, {:error, :no_slot}, state}
    end
  end

  @impl GenServer
  def handle_cast({:checkin_conn, conn_pid}, state) do
    case Map.get(state.connections, conn_pid) do
      nil ->
        # Connection not found, ignore
        {:noreply, state}

      free_slots when free_slots < 10 ->
        # Increment free slots
        new_connections = Map.update!(state.connections, conn_pid, &(&1 + 1))
        {:noreply, %{state | connections: new_connections}}

      _ ->
        # Already at max slots, ignore
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, conn_pid, _reason}, state) do
    # Remove dead connection
    new_connections = Map.delete(state.connections, conn_pid)
    Logger.info("Connection to #{state.uri} died, removed from pool")
    {:noreply, %{state | connections: new_connections}}
  end

  @impl GenServer
  def handle_info({:event, conn_pid, sub_id, event}, state) do
    # Forward event to the query process
    # We need to find which query process is using this connection
    # For now, we'll broadcast to all waiting callers
    Enum.each(state.waiting, fn {caller_pid, _ref} ->
      send(caller_pid, {:event, conn_pid, sub_id, event})
    end)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:eose, conn_pid, sub_id}, state) do
    # Forward EOSE to the query process
    Enum.each(state.waiting, fn {caller_pid, _ref} ->
      send(caller_pid, {:eose, conn_pid, sub_id})
    end)
    {:noreply, state}
  end

  defp find_available_connection(state) do
    case Enum.find(state.connections, fn {_pid, free_slots} -> free_slots > 0 end) do
      {conn_pid, _free_slots} -> {:ok, conn_pid}
      nil -> {:error, :no_slot}
    end
  end

  @spec start_new_connection(String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  defp start_new_connection(uri, caller_pid) do
    Logger.info("Starting new connection to #{uri}")
    case Nostr.Connection.start_link(uri, caller_pid) do
      {:ok, conn_pid} ->
        Logger.info("Successfully started connection to #{uri}")
        # Monitor the connection
        Process.monitor(conn_pid)
        {:ok, conn_pid}

      {:error, {:already_started, pid}} ->
        # Connection already exists; reuse it
        Logger.info("Reusing existing connection to #{uri}")
        Process.monitor(pid)
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start connection to #{uri}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp via(uri) do
    {:via, Registry, {Registry.NostrRelayPools, {__MODULE__, uri}}}
  end
end
