defmodule NervesMOTD.Runtime do
  @moduledoc false
  @callback applications() :: %{started: [atom()], loaded: [atom()]}
  @callback cpu_temperature() :: {:ok, float()} | :error
  @callback active_partition() :: String.t()
  @callback firmware_validity() :: :valid | :invalid | :unknown
  @callback load_average() :: [String.t()]
  @callback memory_stats() ::
              {:ok,
               %{
                 size_mb: non_neg_integer(),
                 used_mb: non_neg_integer(),
                 used_percent: non_neg_integer()
               }}
              | :error
  @callback filesystem_stats(String.t()) ::
              {:ok,
               %{
                 size_mb: non_neg_integer(),
                 used_mb: non_neg_integer(),
                 used_percent: non_neg_integer()
               }}
              | :error
  @callback time_synchronized?() :: boolean()
end

defmodule NervesMOTD.Runtime.Target do
  @moduledoc false
  @behaviour NervesMOTD.Runtime

  alias Nerves.Runtime.KV

  @impl NervesMOTD.Runtime
  def applications() do
    started = Enum.map(Application.started_applications(), &elem(&1, 0))
    loaded = Enum.map(Application.loaded_applications(), &elem(&1, 0))

    %{started: started, loaded: loaded}
  end

  @impl NervesMOTD.Runtime
  def cpu_temperature() do
    # Read the file /sys/class/thermal/thermal_zone0/temp. The file content is
    # an integer in millidegree Celsius, which looks like:
    #
    #     39008\n

    with {:ok, content} <- File.read("/sys/class/thermal/thermal_zone0/temp"),
         {millidegree_c, _} <- Integer.parse(content) do
      {:ok, millidegree_c / 1000}
    else
      _error -> :error
    end
  end

  @impl NervesMOTD.Runtime
  def active_partition() do
    case KV.get("nerves_fw_active") do
      nil -> "unknown"
      partition -> String.upcase(partition)
    end
  end

  @impl NervesMOTD.Runtime
  def firmware_validity() do
    if Nerves.Runtime.firmware_valid?(), do: :valid, else: :invalid
  end

  @impl NervesMOTD.Runtime
  def load_average() do
    case File.read("/proc/loadavg") do
      {:ok, data_str} -> String.split(data_str, " ")
      _ -> []
    end
  end

  @impl NervesMOTD.Runtime
  def memory_stats() do
    # Use free to determine memory statistics. free's output looks like:
    #
    #                   total        used        free      shared  buff/cache   available
    #     Mem:         316664       65184      196736          16       54744      253472
    #     Swap:             0           0           0

    {free_output, 0} = System.cmd("free", [])
    [_title_row, memory_row | _] = String.split(free_output, "\n")
    [_title_column | memory_columns] = String.split(memory_row)
    [size_kb, used_kb, _, _, _, _] = Enum.map(memory_columns, &String.to_integer/1)
    size_mb = round(size_kb / 1000)
    used_mb = round(used_kb / 1000)
    used_percent = round(used_mb / size_mb * 100)

    {:ok, %{size_mb: size_mb, used_mb: used_mb, used_percent: used_percent}}
  rescue
    # In case the `free` command is not available or any of the out parses incorrectly
    _error -> :error
  end

  @impl NervesMOTD.Runtime
  def filesystem_stats(filename) when is_binary(filename) do
    # Use df to determine filesystem statistics. df's output looks like:
    #
    #     Filesystem           1M-blocks      Used Available Use% Mounted on
    #     /dev/mmcblk0p4            1534       205      1329  13% /root

    {df_results, 0} = System.cmd("df", ["-m", filename])
    [_title_row, results_row | _] = String.split(df_results, "\n")
    [_fs, size_mb_str, used_mb_str, _avail, used_percent_str | _] = String.split(results_row)
    {size_mb, ""} = Integer.parse(size_mb_str)
    {used_mb, ""} = Integer.parse(used_mb_str)
    {used_percent, "%"} = Integer.parse(used_percent_str)

    {:ok, %{size_mb: size_mb, used_mb: used_mb, used_percent: used_percent}}
  rescue
    # In case the `df` command is not available or any of the out parses incorrectly
    _error -> :error
  end

  case Code.ensure_compiled(NervesTime) do
    {:module, _} ->
      @impl NervesMOTD.Runtime
      def time_synchronized?(), do: NervesTime.synchronized?()

    _ ->
      @impl NervesMOTD.Runtime
      def time_synchronized?(), do: true
  end
end
