defmodule MdnsLite.Cache do
  @moduledoc """
  Cache for records received over mDNS
  """
  import MdnsLite.DNS
  alias MdnsLite.DNS

  # NOTE: This implementation is not efficient at all. This shouldn't
  #       matter that much since it's not expected that there will be many
  #       records and it won't be called that often.

  @typedoc "Timestamp in seconds (assumed monotonic)"
  @type timestamp() :: integer()

  # Don't allow records to last more than 75 minutes
  @max_ttl 75 * 60

  # Only cache a subset of record types
  @cache_types [:a, :aaaa, :ptr, :txt, :srv]

  # Restrict how many records are cached
  @max_records 200

  defstruct last_gc: -2_147_483_648, records: []
  @type t() :: %__MODULE__{last_gc: timestamp(), records: [DNS.dns_rr()]}

  @doc """
  Start an empty cache
  """
  @spec new() :: %__MODULE__{last_gc: -2_147_483_648, records: []}
  def new() do
    %__MODULE__{}
  end

  @doc """
  Run a query against the cache

  IMPORTANT: The cache is not garbage collected, so it can return stale entries.
  Call `gc/2` first to expire old entries.
  """
  @spec query(t(), DNS.dns_query()) :: %{answer: [DNS.dns_rr()], additional: [DNS.dns_rr()]}
  def query(cache, query) do
    answer = MdnsLite.Table.query(cache.records, query, %MdnsLite.IfInfo{})
    additional = MdnsLite.Table.additional_records(cache.records, answer, %MdnsLite.IfInfo{})
    %{answer: answer, additional: additional}
  end

  @doc """
  Remove any expired entries
  """
  @spec gc(t(), timestamp()) :: t()
  def gc(%{last_gc: last_time} = cache, time) when time > last_time do
    seconds_elapsed = time - last_time
    new_records = Enum.reduce(cache.records, [], &gc_record(&1, &2, seconds_elapsed))
    %{cache | records: new_records, last_gc: time}
  end

  def gc(cache, _time) do
    cache
  end

  defp gc_record(record, acc, seconds_elapsed) do
    new_ttl = dns_rr(record, :ttl) - seconds_elapsed

    if new_ttl > 0 do
      [dns_rr(record, ttl: new_ttl) | acc]
    else
      acc
    end
  end

  @doc """
  Insert a record into the cache
  """
  @spec insert(t(), timestamp(), DNS.dns_rr()) :: t()
  def insert(cache, time, record) do
    insert_many(cache, time, [record])
  end

  @doc """
  Insert several record into the cache
  """
  @spec insert_many(t(), timestamp(), [DNS.dns_rr()]) :: t()
  def insert_many(cache, time, records) do
    records = records |> Enum.filter(&valid_record?/1) |> Enum.map(&normalize_record/1)

    if records != [] do
      cache
      |> gc(time)
      |> drop_if_full(Enum.count(records))
      |> do_insert_many(records)
    else
      cache
    end
  end

  defp do_insert_many(cache, records) do
    Enum.reduce(records, cache, &do_insert(&2, &1))
  end

  defp do_insert(cache, record) do
    %{cache | records: insert_or_update(cache.records, record, [])}
  end

  defp insert_or_update([], new_rr, result) do
    [new_rr | result]
  end

  defp insert_or_update(
         [dns_rr(class: c, type: t, domain: d, data: x) | rest],
         dns_rr(class: c, type: t, domain: d, data: x) = new_rr,
         result
       ) do
    [new_rr | rest] ++ result
  end

  defp insert_or_update([rr | rest], new_rr, result) do
    insert_or_update(rest, new_rr, [rr | result])
  end

  defp normalize_record(dns_rr(ttl: ttl) = record) do
    dns_rr(record, ttl: normalize_ttl(ttl))
  end

  defp normalize_ttl(ttl) when ttl > @max_ttl, do: @max_ttl
  defp normalize_ttl(ttl) when ttl < 1, do: 1
  defp normalize_ttl(ttl), do: ttl

  defp valid_record?(dns_rr(type: t)) when t in @cache_types, do: true
  defp valid_record?(_other), do: false

  defp drop_if_full(cache, count) do
    %{cache | records: Enum.take(cache.records, @max_records - count)}
  end
end
