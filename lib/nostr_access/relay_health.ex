defmodule NostrAccess.RelayHealth do
  @moduledoc """
  Tracks relay reliability and selects relays based on recent health signals.
  """

  require Logger

  @cache :nostr_relay_health_cache

  @type relay_state :: %{
          score: non_neg_integer(),
          failure_timestamps: [non_neg_integer()],
          failure_entries: [map()],
          cooldown_until: non_neg_integer() | nil,
          last_failure_at: non_neg_integer() | nil,
          last_success_at: non_neg_integer() | nil
        }

  @spec available_relays([String.t()]) :: [String.t()]
  def available_relays(relay_urls) when is_list(relay_urls) do
    if enabled?() do
      now = now_unix()
      unique = Enum.uniq(relay_urls)
      scored = Enum.map(unique, fn url -> {url, state_for(url)} end)

      preferred =
        scored
        |> Enum.filter(fn {_url, state} -> usable?(state, now) end)
        |> Enum.sort_by(fn {_url, state} -> state.score end, :desc)
        |> Enum.map(&elem(&1, 0))
        |> Enum.take(max_relays())

      selected =
        if length(preferred) < min_relays() do
          # If none pass the filter, fall back to highest-score relays.
          scored
          |> Enum.sort_by(fn {_url, state} -> state.score end, :desc)
          |> Enum.map(&elem(&1, 0))
          |> Enum.take(max_relays())
        else
          preferred
        end

      if selected == [] do
        relay_urls
      else
        selected
      end
    else
      relay_urls
    end
  end

  @spec record_success(String.t()) :: :ok
  def record_success(relay_url) when is_binary(relay_url) do
    update_state(relay_url, fn state ->
      now = now_unix()
      pruned = prune_failures(state.failure_timestamps, now)
      pruned_entries = prune_failure_entries(state.failure_entries, now)

      state
      |> Map.put(:failure_timestamps, pruned)
      |> Map.put(:failure_entries, pruned_entries)
      |> Map.put(:last_success_at, now)
      |> Map.update!(:score, &min(&1 + success_inc(), max_score()))
      |> clear_expired_cooldown(now)
    end)
  end

  @spec record_failure(String.t(), term()) :: :ok
  def record_failure(relay_url, reason) when is_binary(relay_url) do
    update_state(relay_url, fn state ->
      now = now_unix()
      pruned = prune_failures(state.failure_timestamps, now)
      pruned_entries = prune_failure_entries(state.failure_entries, now)
      failures = [now | pruned]
      failure_entries = [%{ts: now, reason: normalize_reason(reason)} | pruned_entries]
      fail_count = length(failures)
      score = max(state.score - failure_dec(), 0)

      cooldown_until =
        cond do
          fail_count >= fail_threshold() -> now + cooldown_seconds()
          score < score_floor() -> now + cooldown_seconds()
          true -> state.cooldown_until
        end

      if fail_count >= fail_threshold() do
        Logger.warning(
          "RelayHealth: cooldown #{relay_url} after #{fail_count} failures (#{inspect(reason)})"
        )
      end

      state
      |> Map.put(:failure_timestamps, failures)
      |> Map.put(:failure_entries, failure_entries)
      |> Map.put(:last_failure_at, now)
      |> Map.put(:cooldown_until, cooldown_until)
      |> Map.put(:score, score)
    end)
  end

  @spec all_states([String.t()]) :: list(map())
  def all_states(relay_urls \\ []) do
    now = now_unix()

    cached =
      case Cachex.keys(@cache) do
        {:ok, keys} -> keys
        _ -> []
      end

    (cached ++ relay_urls)
    |> Enum.uniq()
    |> Enum.map(fn relay_url ->
      state =
        case Cachex.get(@cache, relay_url) do
          {:ok, state} when is_map(state) -> state
          _ -> default_state()
        end

      state
      |> Map.put(:relay_url, relay_url)
      |> Map.put(:usable, usable?(state, now))
    end)
  end

  @spec reconnect_allowed?(String.t()) :: boolean()
  def reconnect_allowed?(relay_url) when is_binary(relay_url) do
    if enabled?() do
      now = now_unix()
      state = state_for(relay_url)
      usable?(state, now)
    else
      true
    end
  end

  @spec ignore_failure_reason?(term()) :: boolean()
  def ignore_failure_reason?(%{code: code}) when code in [1000, 1001], do: true
  def ignore_failure_reason?(%{reason: {:remote, :closed}}), do: true
  def ignore_failure_reason?(%{reason: {:remote, :normal}}), do: true
  def ignore_failure_reason?(%{reason: {:close, 1000, _}}), do: true
  def ignore_failure_reason?(%{reason: {:close, 1001, _}}), do: true
  def ignore_failure_reason?({:remote, code, _reason}) when code in [1000, 1001], do: true
  def ignore_failure_reason?({:close, code, _reason}) when code in [1000, 1001], do: true
  def ignore_failure_reason?(_reason), do: false

  defp enabled? do
    config(:enabled, true)
  end

  defp usable?(%{score: score, cooldown_until: cooldown_until}, now) do
    score >= score_floor() and (is_nil(cooldown_until) or cooldown_until <= now)
  end

  defp state_for(relay_url) do
    case Cachex.get(@cache, relay_url) do
      {:ok, nil} -> default_state()
      {:ok, state} when is_map(state) -> Map.merge(default_state(), state)
      _ -> default_state()
    end
  end

  defp update_state(relay_url, fun) do
    state = state_for(relay_url)
    updated = fun.(state)
    ttl = :timer.hours(config(:ttl_hours, 24))
    _ = Cachex.put(@cache, relay_url, updated, ttl: ttl)
    :ok
  end

  defp prune_failures(timestamps, now) do
    window_start = now - window_seconds()
    Enum.filter(timestamps, &(&1 >= window_start))
  end

  defp prune_failure_entries(entries, now) do
    window_start = now - window_seconds()

    entries
    |> Enum.filter(fn entry ->
      case entry do
        %{ts: ts} when is_integer(ts) -> ts >= window_start
        _ -> false
      end
    end)
  end

  defp clear_expired_cooldown(state, now) do
    case state.cooldown_until do
      nil -> state
      cooldown_until when cooldown_until <= now -> Map.put(state, :cooldown_until, nil)
      _ -> state
    end
  end

  defp default_state do
    %{
      score: max_score(),
      failure_timestamps: [],
      failure_entries: [],
      cooldown_until: nil,
      last_failure_at: nil,
      last_success_at: nil
    }
  end

  defp normalize_reason(%{reason: inner}) do
    normalize_reason(inner)
  end

  defp normalize_reason(%{code: code, message: message})
       when is_integer(code) and is_binary(message) do
    "RequestError code=#{code} message=#{message}"
  end

  defp normalize_reason({:remote, code, reason}) do
    "remote code=#{code} reason=#{inspect(reason, limit: 5)}"
  end

  defp normalize_reason({:close, code, reason}) do
    "close code=#{code} reason=#{inspect(reason, limit: 5)}"
  end

  defp normalize_reason(other) do
    inspect(other, limit: 5)
  end

  defp now_unix do
    System.system_time(:second)
  end

  defp config(key, default) do
    :nostr_access
    |> Application.get_env(:relay_health, [])
    |> Keyword.get(key, default)
  end

  defp window_seconds, do: config(:fail_window_minutes, 5) * 60
  defp cooldown_seconds, do: config(:cooldown_minutes, 10) * 60
  defp fail_threshold, do: config(:fail_threshold, 3)
  defp score_floor, do: config(:score_floor, 40)
  defp max_relays, do: config(:max_relays, 6)
  defp min_relays, do: config(:min_relays, 1)
  defp success_inc, do: config(:success_inc, 5)
  defp failure_dec, do: config(:failure_dec, 15)
  defp max_score, do: config(:max_score, 100)
end
