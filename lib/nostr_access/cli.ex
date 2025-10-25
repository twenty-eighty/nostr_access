defmodule NostrAccess.CLI do
  @moduledoc """
  Command-line interface for nostr_access following the nak tool syntax.
  """

  @version "0.1.0"

  def main(args \\ System.argv()) do
    case parse_args(args) do
      {:ok, opts} ->
        run(opts)

      {:error, message} ->
        IO.puts(:stderr, "Error: #{message}")
        System.halt(1)
    end
  end

  defp parse_args(args) do
    # First, collect all values for array options manually
    {array_opts, remaining_args} = collect_array_values(args, %{})

    case OptionParser.parse(remaining_args, strict: strict_opts(), aliases: aliases()) do
      {opts, relay_args, []} ->
        # Merge array options with regular options
        merged_opts = merge_array_opts(opts, array_opts)
        {:ok, build_opts(merged_opts, relay_args)}

      {_opts, _args, [{flag, _value} | _]} ->
        {:error, "Unknown option: #{flag}"}
    end
  end

  defp collect_array_values(args, acc) do
    collect_array_values(args, acc, [])
  end

  defp collect_array_values([], acc, remaining) do
    {acc, Enum.reverse(remaining)}
  end

  defp collect_array_values(["--author", value | rest], acc, remaining) do
    authors = Map.get(acc, :author, [])
    collect_array_values(rest, Map.put(acc, :author, [value | authors]), remaining)
  end

  defp collect_array_values(["-a", value | rest], acc, remaining) do
    authors = Map.get(acc, :author, [])
    collect_array_values(rest, Map.put(acc, :author, [value | authors]), remaining)
  end

  defp collect_array_values(["--id", value | rest], acc, remaining) do
    ids = Map.get(acc, :id, [])
    collect_array_values(rest, Map.put(acc, :id, [value | ids]), remaining)
  end

  defp collect_array_values(["-i", value | rest], acc, remaining) do
    ids = Map.get(acc, :id, [])
    collect_array_values(rest, Map.put(acc, :id, [value | ids]), remaining)
  end

  defp collect_array_values(["--kind", value | rest], acc, remaining) do
    kinds = Map.get(acc, :kind, [])
    collect_array_values(rest, Map.put(acc, :kind, [value | kinds]), remaining)
  end

  defp collect_array_values(["-k", value | rest], acc, remaining) do
    kinds = Map.get(acc, :kind, [])
    collect_array_values(rest, Map.put(acc, :kind, [value | kinds]), remaining)
  end

  defp collect_array_values(["--tag", value | rest], acc, remaining) do
    tags = Map.get(acc, :tag, [])
    collect_array_values(rest, Map.put(acc, :tag, [value | tags]), remaining)
  end

  defp collect_array_values(["-t", value | rest], acc, remaining) do
    tags = Map.get(acc, :tag, [])
    collect_array_values(rest, Map.put(acc, :tag, [value | tags]), remaining)
  end

  defp collect_array_values(["-d", value | rest], acc, remaining) do
    d_tags = Map.get(acc, :d, [])
    collect_array_values(rest, Map.put(acc, :d, [value | d_tags]), remaining)
  end

  defp collect_array_values(["-e", value | rest], acc, remaining) do
    e_tags = Map.get(acc, :e, [])
    collect_array_values(rest, Map.put(acc, :e, [value | e_tags]), remaining)
  end

  defp collect_array_values(["-p", value | rest], acc, remaining) do
    p_tags = Map.get(acc, :p, [])
    collect_array_values(rest, Map.put(acc, :p, [value | p_tags]), remaining)
  end

  defp collect_array_values([arg | rest], acc, remaining) do
    collect_array_values(rest, acc, [arg | remaining])
  end

  defp merge_array_opts(opts, array_opts) do
    Enum.reduce(array_opts, opts, fn {key, values}, acc ->
      Keyword.put(acc, key, Enum.reverse(values))
    end)
  end

  defp get_array_values(opts, key) do
    case Keyword.get(opts, key) do
      nil -> []
      value when is_list(value) -> value
      value -> [value]
    end
  end

  defp strict_opts do
    [
      # Filter attributes
      author: :string,
      id: :string,
      kind: :integer,
      limit: :integer,
      search: :string,
      since: :integer,
      tag: :string,
      until: :integer,
      d: :string,
      e: :string,
      p: :string,

      # Pagination
      paginate: :boolean,
      paginate_global_limit: :integer,
      paginate_interval: :string,

      # Output options
      bare: :boolean,
      stream: :boolean,
      ids_only: :boolean,

      # Global options
      help: :boolean,
      quiet: :boolean,
      verbose: :boolean,
      version: :boolean,

      # Publish options
      publish: :boolean,
      event: :string,
      min_ok: :integer
    ]
  end

  defp aliases do
    [
      a: :author,
      i: :id,
      k: :kind,
      l: :limit,
      s: :since,
      t: :tag,
      u: :until,
      h: :help,
      q: :quiet,
      v: :verbose
    ]
  end

  defp build_opts(opts, args) do
    # Handle multiple values for array options
    authors = get_array_values(opts, :author)
    ids = get_array_values(opts, :id)
    kinds = get_array_values(opts, :kind) |> Enum.map(&String.to_integer/1)
    tags = get_array_values(opts, :tag)

    # Handle shortcut tag options
    d_tags = get_array_values(opts, :d)
    e_tags = get_array_values(opts, :e)
    p_tags = get_array_values(opts, :p)

    # Build tags map
    tags_map = build_tags_map(tags, d_tags, e_tags, p_tags)

    # Build filter
    filter = %{}
    filter = if authors != [], do: Map.put(filter, :authors, authors), else: filter
    filter = if ids != [], do: Map.put(filter, :ids, ids), else: filter
    filter = if kinds != [], do: Map.put(filter, :kinds, kinds), else: filter
    filter = if opts[:limit], do: Map.put(filter, :limit, opts[:limit]), else: filter
    filter = if opts[:search], do: Map.put(filter, :search, opts[:search]), else: filter
    filter = if opts[:since], do: Map.put(filter, :since, opts[:since]), else: filter
    filter = if opts[:until], do: Map.put(filter, :until, opts[:until]), else: filter
    filter = Map.merge(filter, tags_map)

    # Build final options
    %{
      filter: filter,
      relays: args,
      paginate: opts[:paginate] || false,
      paginate_global_limit: opts[:paginate_global_limit],
      paginate_interval: parse_interval(opts[:paginate_interval]),
      bare: opts[:bare] || false,
      stream: opts[:stream] || false,
      ids_only: opts[:ids_only] || false,
      quiet: opts[:quiet] || false,
      verbose: opts[:verbose] || false,
      help: opts[:help] || false,
      version: opts[:version] || false,
      publish: opts[:publish] || false,
      event: opts[:event],
      min_ok: opts[:min_ok]
    }
  end

  defp build_tags_map(tags, d_tags, e_tags, p_tags) do
    tags_map = %{}

    # Parse explicit tags
    tags_map =
      Enum.reduce(tags, tags_map, fn tag, acc ->
        case String.split(tag, "=", parts: 2) do
          [key, value] -> Map.put(acc, "#{key}", [value])
          _ -> acc
        end
      end)

    # Handle shortcut tags
    tags_map = if d_tags != [], do: Map.put(tags_map, "#d", d_tags), else: tags_map
    tags_map = if e_tags != [], do: Map.put(tags_map, "#e", e_tags), else: tags_map
    tags_map = if p_tags != [], do: Map.put(tags_map, "#p", p_tags), else: tags_map

    tags_map
  end

  defp parse_interval(nil), do: 0

  defp parse_interval(interval_str) do
    case parse_duration(interval_str) do
      # Convert to milliseconds
      {:ok, seconds} -> seconds * 1000
      _ -> 0
    end
  end

  defp parse_duration(duration_str) do
    case Regex.run(~r/^(\d+)([smhd])$/, duration_str) do
      [_, amount, unit] ->
        amount = String.to_integer(amount)

        seconds =
          case unit do
            "s" -> amount
            "m" -> amount * 60
            "h" -> amount * 3600
            "d" -> amount * 86400
          end

        {:ok, seconds}

      _ ->
        :error
    end
  end

  defp run(%{help: true}) do
    print_help()
  end

  defp run(%{version: true}) do
    IO.puts("nostr_access #{@version}")
  end

  defp run(opts) do
    if opts.verbose do
      IO.puts(:stderr, "Filter: #{inspect(opts.filter)}")
      IO.puts(:stderr, "Relays: #{inspect(opts.relays)}")
    end

    if opts.publish do
      execute_publish(opts)
    else
      case opts.relays do
        [] ->
          # Just print the filter
          if opts.bare do
            IO.puts(Jason.encode!(opts.filter))
          else
            sub_id = generate_sub_id()
            req = ["REQ", sub_id, opts.filter]
            IO.puts(Jason.encode!(req))
          end

        relays ->
          # Connect to relays and send filter
          execute_query(opts, relays)
      end
    end
  end

  defp execute_publish(opts) do
    with {:ok, event} <- fetch_event_json(opts),
         relays when is_list(relays) <- opts.relays do
      min_ok = opts.min_ok || 1

      unless opts.quiet do
        IO.puts(:stderr, "Publishing to relays: #{inspect(relays)} (min_ok=#{min_ok})")
      end

      case Nostr.Client.publish(relays, event, min_ok: min_ok) do
        {:ok, result} ->
          unless opts.quiet do
            IO.puts(:stderr, "OK from #{result.ok}/#{result.total} relays")
          end

          IO.puts(Jason.encode!(result))

        {:error, {:min_ok_not_met, result}} ->
          unless opts.quiet do
            IO.puts(:stderr, "Minimum OK not met: #{result.ok}/#{result.total}")
          end

          IO.puts(Jason.encode!(result))
          System.halt(2)

        {:error, reason} ->
          unless opts.quiet do
            IO.puts(:stderr, "Error: #{inspect(reason)}")
          end

          System.halt(1)
      end
    else
      {:error, msg} ->
        IO.puts(:stderr, "Error: #{msg}")
        System.halt(1)
    end
  end

  defp fetch_event_json(%{event: event_json}) when is_binary(event_json) do
    case Jason.decode(event_json) do
      {:ok, ev} when is_map(ev) -> {:ok, ev}
      _ -> {:error, "--event must be valid JSON"}
    end
  end

  defp fetch_event_json(_opts) do
    input = IO.binread(:stdio, :all)
    case input do
      data when is_binary(data) ->
        trimmed = String.trim(data)
        if trimmed != "" do
          case Jason.decode(trimmed) do
            {:ok, ev} when is_map(ev) -> {:ok, ev}
            _ -> {:error, "stdin does not contain a valid JSON event"}
          end
        else
          {:error, "No event provided. Use --event '{...}' or pipe JSON on stdin."}
        end

      _ ->
        {:error, "No event provided. Use --event '{...}' or pipe JSON on stdin."}
    end
  end

  defp execute_query(opts, relays) do
    if opts.paginate do
      execute_paginated_query(opts, relays)
    else
      execute_single_query(opts, relays)
    end
  end

  defp execute_single_query(opts, relays) do
    if opts.stream do
      execute_stream_query(opts, relays)
    else
      execute_fetch_query(opts, relays)
    end
  end

  defp execute_fetch_query(opts, relays) do
    unless opts.quiet do
      IO.puts(:stderr, "Querying relays: #{inspect(relays)}")
      IO.puts(:stderr, "Filter: #{inspect(opts.filter)}")
    end

    case Nostr.Client.fetch(relays, opts.filter, cache?: false) do
      {:ok, events} ->
        unless opts.quiet do
          IO.puts(:stderr, "Received #{length(events)} events")
        end

        print_events(events, opts)

      {:error, reason} ->
        unless opts.quiet do
          IO.puts(:stderr, "Error: #{inspect(reason)}")
        end

        System.halt(1)
    end
  end

  @spec execute_stream_query(map(), [String.t()]) :: :ok
  defp execute_stream_query(opts, relays) do
    case Nostr.Client.stream(relays, opts.filter) do
      {:ok, query_ref} ->
        stream_events(query_ref, opts)
        :ok

      {:error, reason} ->
        unless opts.quiet do
          IO.puts(:stderr, "Error: #{inspect(reason)}")
        end

        System.halt(1)
    end
  end

  # Dialyzer: false positives due to complex return type inference
  @dialyzer {:no_return, execute_stream_query: 2}
  @dialyzer {:no_match, execute_stream_query: 2}

  defp execute_paginated_query(opts, relays) do
    global_limit = opts.paginate_global_limit || opts.filter[:limit] || :infinity
    interval = opts.paginate_interval

    paginate_events(opts, relays, global_limit, interval, [])
  end

  defp paginate_events(opts, relays, global_limit, interval, all_events) do
    # Check if we've reached the global limit
    if global_limit != :infinity and length(all_events) >= global_limit do
      print_events(Enum.take(all_events, global_limit), opts)
    else
      # Execute current query
      case Nostr.Client.fetch(relays, opts.filter, cache?: false) do
        {:ok, events} ->
          new_all_events = all_events ++ events

          if length(events) == 0 do
            # No more events, we're done
            print_events(new_all_events, opts)
          else
            # Update filter for next iteration
            last_event = List.last(events)
            until_timestamp = get_event_timestamp(last_event)

            new_filter = Map.put(opts.filter, :until, until_timestamp)
            new_opts = Map.put(opts, :filter, new_filter)

            # Wait for interval if specified
            if interval > 0 do
              :timer.sleep(interval)
            end

            paginate_events(new_opts, relays, global_limit, interval, new_all_events)
          end

        {:error, reason} ->
          unless opts.quiet do
            IO.puts(:stderr, "Error: #{inspect(reason)}")
          end

          System.halt(1)
      end
    end
  end

  defp get_event_timestamp(event) do
    case event["created_at"] do
      timestamp when is_integer(timestamp) -> timestamp
      _ -> System.system_time(:second)
    end
  end

  # Dialyzer: false positives - functions are called but Dialyzer can't see the call chain
  @dialyzer {:no_unused, stream_events: 2}
  @dialyzer {:no_unused, stream_events_loop: 2}

  defp stream_events(query_ref, opts) do
    stream_events_loop(query_ref, opts)
  end

  defp stream_events_loop(query_ref, opts) do
    receive do
      {:nostr_event, ^query_ref, event} ->
        print_event(event, opts)
        stream_events_loop(query_ref, opts)

      {:nostr_eose, ^query_ref, true} ->
        # All relays finished
        :ok

      {:nostr_eose, ^query_ref, false} ->
        # One relay finished, continue listening
        stream_events_loop(query_ref, opts)
    end
  end

  defp print_events(events, opts) do
    if opts.ids_only do
      Enum.each(events, fn event ->
        IO.puts(event["id"])
      end)
    else
      Enum.each(events, fn event ->
        print_event(event, opts)
      end)
    end
  end

  defp print_event(event, opts) do
    if opts.bare do
      IO.puts(Jason.encode!(event))
    else
      IO.puts(Jason.encode!(event))
    end
  end

  defp generate_sub_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp print_help do
    IO.puts("""
    NAME:
       nostr_access req - generates encoded REQ messages and optionally use them to talk to relays

    USAGE:
       nostr_access req [command [command options]] [relay...]

    DESCRIPTION:
       outputs a nip01 Nostr filter. when a relay is not given, will print the filter, otherwise will connect to the given relay and send the filter.

       example:
           nostr_access req -k 1 -l 15 wss://nostr.wine wss://nostr-pub.wellorder.net
           nostr_access req -k 0 -a 3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d wss://nos.lol | jq '.content | fromjson | .name'

       it can also take a filter from stdin, optionally modify it with flags and send it to specific relays (or just print it).

       example:
           echo '{"kinds": [1], "#t": ["test"]}' | nostr_access req -l 5 -k 4549 --tag t=spam wss://nostr-pub.wellorder.net

    OPTIONS:
       --bare                         when printing the filter, print just the filter, not enveloped in a ["REQ", ...] array (default: false)
       --help, -h                     show help
       --ids-only                     use nip77 to fetch just a list of ids (default: false)
       --paginate                     make multiple REQs to the relay decreasing the value of 'until' until 'limit' or 'since' conditions are met (default: false)
       --paginate-global-limit value  global limit at which --paginate should stop (default: uses the value given by --limit/-l or infinite)
       --paginate-interval value      time between queries when using --paginate (default: 0s)
       --stream                       keep the subscription open, printing all events as they are returned (default: false, will close on EOSE)

       FILTER ATTRIBUTES

       --author value, -a value [ --author value, -a value ]  only accept events from these authors (pubkey as hex)
       --id value, -i value [ --id value, -i value ]          only accept events with these ids (hex)
       --kind value, -k value [ --kind value, -k value ]      only accept events with these kind numbers
       --limit value, -l value                                only accept up to this number of events (default: 0)
       --search value                                         a nip50 search query, use it only with relays that explicitly support it
       --since value, -s value                                only accept events newer than this (unix timestamp) (default: 1970-01-01 01:00:00 +0100 CET)
       --tag value, -t value [ --tag value, -t value ]        takes a tag like -t e=<id>, only accept events with these tags
       --until value, -u value                                only accept events older than this (unix timestamp) (default: 1970-01-01 01:00:00 +0100 CET)
       -d value [ -d value ]                                  shortcut for --tag d=<value>
       -e value [ -e value ]                                  shortcut for --tag e=<value>
       -p value [ -p value ]                                  shortcut for --tag p=<value>

    GLOBAL OPTIONS:
       --quiet, -q    do not print logs and info messages to stderr, use -qq to also not print anything to stdout (default: false)
       --verbose, -v  print more stuff than normally (default: false)
       --version      prints the version (default: false)
    """)
  end
end
