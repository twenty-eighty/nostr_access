defmodule Nostr.Cache do
  @moduledoc """
  Cache management for Nostr events with three-tier caching:
  - Zero results cache (TTL: 1 hour)
  - Immutable results cache (TTL: 1 day) - for queries with specific event IDs
  - Mutable results cache (TTL: 30 minutes) - for all other queries
  """

  @zero_results_table :nostr_cache_zero_results
  @immutable_table :nostr_cache_immutable
  @mutable_table :nostr_cache_mutable

  @doc """
  Gets a value from cache or stores the result of the given function.
  """
  @spec get_or_store({[String.t()], String.t()}, map(), (-> [map()])) :: [map()]
  def get_or_store(key, filter, fun) do
    # Try all cache tables in order of preference
    case try_get_from_all_caches(key, filter) do
      {:ok, cached} ->
        cached

      {:error, _} ->
        # No cache hit, execute function and store result
        result = fun.()
        result_table = determine_cache_table(filter, result)
        Cachex.put(result_table, key, result)
        result
    end
  end

  @doc """
  Tries to get a value from all cache tables in order of preference.
  """
  @spec try_get_from_all_caches({[String.t()], String.t()}, map()) ::
          {:ok, [map()]} | {:error, :not_found}
  def try_get_from_all_caches(key, filter) do
    # Try immutable cache first (if query has specific IDs)
    if Map.has_key?(filter, :ids) and is_list(filter.ids) and length(filter.ids) > 0 do
      case Cachex.get(@immutable_table, key) do
        {:ok, cached} when is_list(cached) and length(cached) > 0 -> {:ok, cached}
        _ -> try_mutable_cache(key)
      end
    else
      try_mutable_cache(key)
    end
  end

  defp try_mutable_cache(key) do
    # Try mutable cache
    case Cachex.get(@mutable_table, key) do
      {:ok, cached} when is_list(cached) and length(cached) > 0 -> {:ok, cached}
      _ -> try_zero_results_cache(key)
    end
  end

  defp try_zero_results_cache(key) do
    # Try zero results cache
    case Cachex.get(@zero_results_table, key) do
      {:ok, []} -> {:ok, []}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Determines which cache table to use based on filter and results.
  """
  @spec determine_cache_table(map(), [map()]) :: atom()
  def determine_cache_table(filter, results) do
    cond do
      # Zero results - use zero results cache
      length(results) == 0 ->
        @zero_results_table

      # Queries with specific event IDs are immutable
      Map.has_key?(filter, :ids) and is_list(filter.ids) and length(filter.ids) > 0 ->
        @immutable_table

      # All other queries are mutable
      true ->
        @mutable_table
    end
  end

  @doc """
  Gets a value from the appropriate cache based on filter.
  """
  @spec get_events({[String.t()], String.t()}, map()) :: {:ok, [map()] | nil} | {:error, term()}
  def get_events(key, filter) do
    case try_get_from_all_caches(key, filter) do
      {:ok, cached} -> {:ok, cached}
      {:error, :not_found} -> {:ok, nil}
    end
  end

  @doc """
  Gets a value from the zero results cache.
  """
  @spec get_zero_results({[String.t()], String.t()}) :: {:ok, [map()] | nil} | {:error, term()}
  def get_zero_results(key) do
    Cachex.get(@zero_results_table, key)
  end

  @doc """
  Stores events in the appropriate cache based on filter and results.
  """
  @spec put_events({[String.t()], String.t()}, [map()], map()) ::
          {:ok, boolean()} | {:error, term()}
  def put_events(key, events, filter) do
    table = determine_cache_table(filter, events)
    Cachex.put(table, key, events)
  end

  @doc """
  Stores zero results in the zero results cache.
  """
  @spec put_zero_results({[String.t()], String.t()}, [map()]) ::
          {:ok, boolean()} | {:error, term()}
  def put_zero_results(key, results) do
    Cachex.put(@zero_results_table, key, results)
  end

  @doc """
  Creates a cache key from relays and filter.
  """
  @spec make_key([String.t()], map()) :: {[String.t()], String.t()}
  def make_key(relays, filter) do
    {Enum.sort(relays), Jason.encode!(filter)}
  end
end
