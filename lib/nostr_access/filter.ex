defmodule Nostr.Filter do
  @moduledoc """
  Validates and canonicalizes NIP-01 filters.
  """

  @doc """
  Validates a NIP-01 filter and returns a canonicalized version.

  ## Examples

      iex> Nostr.Filter.validate!(%{kinds: [1, 2], authors: ["pubkey"]})
      %{authors: ["pubkey"], kinds: [1, 2]}

      iex> Nostr.Filter.validate!(%{since: 1234567890})
      %{since: 1234567890}
  """
  @spec validate!(map()) :: map()
  def validate!(filter) when is_map(filter) do
    filter
    |> normalize_keys_and_values()
    |> validate_fields!()
    |> canonicalize()
  end

  def validate!(filter) do
    raise ArgumentError, "Filter must be a map, got: #{inspect(filter)}"
  end

  # Normalize filters that come from JSON or external callers using string keys
  # - Convert known NIP-01 keys from strings to atoms
  # - Coerce kinds list items from strings to integers when possible
  defp normalize_keys_and_values(filter) do
    Enum.reduce(filter, %{}, fn {key, value}, acc ->
      case key do
        # Known keys as strings → atoms
        "ids" ->
          Map.put(acc, :ids, value)

        "authors" ->
          Map.put(acc, :authors, value)

        "kinds" ->
          Map.put(acc, :kinds, normalize_kinds_value(value))

        "since" ->
          Map.put(acc, :since, value)

        "until" ->
          Map.put(acc, :until, value)

        "limit" ->
          Map.put(acc, :limit, value)

        "search" ->
          Map.put(acc, :search, value)

        # Any other binary keys (including custom tags like "#e", "#p") stay as strings
        bin when is_binary(bin) ->
          Map.put(acc, bin, value)

        # If already atoms, keep, but normalize kinds values
        :kinds ->
          Map.put(acc, :kinds, normalize_kinds_value(value))

        atom when is_atom(atom) ->
          atom_str = Atom.to_string(atom)

          if String.starts_with?(atom_str, "#") do
            # Normalize tag atoms like :"#d" to string keys "#d"
            Map.put(acc, atom_str, value)
          else
            Map.put(acc, atom, value)
          end

        # Fallback: keep as-is
        other ->
          Map.put(acc, other, value)
      end
    end)
  end

  defp normalize_kinds_value(kinds) when is_list(kinds) do
    Enum.map(kinds, fn
      int when is_integer(int) ->
        int

      bin when is_binary(bin) ->
        case Integer.parse(bin) do
          {int, ""} -> int
          _ -> bin
        end

      other ->
        other
    end)
  end

  defp normalize_kinds_value(other), do: other

  defp validate_fields!(filter) do
    Enum.reduce(filter, %{}, fn {key, value}, acc ->
      validate_field!(key, value)
      Map.put(acc, key, value)
    end)
  end

  defp validate_field!(:ids, ids) when is_list(ids) do
    unless Enum.all?(ids, &is_binary/1) do
      raise ArgumentError, "Filter :ids must be a list of strings"
    end
  end

  defp validate_field!(:authors, authors) when is_list(authors) do
    unless Enum.all?(authors, &is_binary/1) do
      raise ArgumentError, "Filter :authors must be a list of strings"
    end
  end

  defp validate_field!(:kinds, kinds) when is_list(kinds) do
    unless Enum.all?(kinds, &is_integer/1) do
      raise ArgumentError, "Filter :kinds must be a list of integers"
    end
  end

  defp validate_field!(:since, since) when is_integer(since) do
    :ok
  end

  defp validate_field!(:until, until) when is_integer(until) do
    :ok
  end

  defp validate_field!(:limit, limit) when is_integer(limit) and limit > 0 do
    :ok
  end

  defp validate_field!(:limit, limit) do
    raise ArgumentError, "Filter :limit must be a positive integer, got: #{inspect(limit)}"
  end

  defp validate_field!(key, value) when is_binary(key) and is_list(value) do
    # Custom tag filters like #e, #p, etc.
    unless Enum.all?(value, &is_binary/1) do
      raise ArgumentError, "Filter tag #{key} must be a list of strings"
    end
  end

  defp validate_field!(key, value) do
    raise ArgumentError, "Invalid filter field #{key}: #{inspect(value)}"
  end

  defp canonicalize(filter) do
    # Convert time fields to integer seconds if they're not already
    filter
    |> convert_time_fields()
    |> sort_arrays()
    |> sort_keys()
  end

  defp convert_time_fields(filter) do
    filter
    |> maybe_convert_time(:since)
    |> maybe_convert_time(:until)
  end

  defp maybe_convert_time(filter, key) do
    case Map.get(filter, key) do
      nil ->
        filter

      value when is_integer(value) ->
        filter

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> Map.put(filter, key, int)
          _ -> filter
        end

      _ ->
        filter
    end
  end

  defp sort_arrays(filter) do
    filter
    |> sort_array_field(:ids)
    |> sort_array_field(:authors)
    |> sort_array_field(:kinds)
  end

  defp sort_array_field(filter, key) do
    case Map.get(filter, key) do
      nil -> filter
      list when is_list(list) -> Map.put(filter, key, Enum.sort(list))
    end
  end

  defp sort_keys(filter) do
    filter
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn key, acc ->
      Map.put(acc, key, Map.get(filter, key))
    end)
  end
end
