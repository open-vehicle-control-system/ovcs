defmodule MdnsLite.TableServer do
  @moduledoc false
  use GenServer

  alias MdnsLite.{DNS, IfInfo, Options, Table}

  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec update_options((Options.t() -> Options.t())) :: :ok
  def update_options(fun) do
    GenServer.call(__MODULE__, {:update_options, fun})
  end

  @spec options() :: Options.t()
  def options() do
    GenServer.call(__MODULE__, :options)
  end

  @spec query(DNS.dns_query(), IfInfo.t()) :: %{
          answer: [DNS.dns_rr()],
          additional: [DNS.dns_rr()]
        }
  def query(query, if_info) do
    GenServer.call(__MODULE__, {:query, query, if_info})
  end

  @spec get_records() :: [DNS.dns_rr()]
  def get_records() do
    GenServer.call(__MODULE__, :get_records)
  end

  ##############################################################################
  #   GenServer callbacks
  ##############################################################################
  @impl GenServer
  def init(opts) do
    {:ok, %{options: opts, table: Table.Builder.from_options(opts)}}
  end

  @impl GenServer
  def handle_call(:options, _from, state) do
    {:reply, state.options, state}
  end

  def handle_call({:update_options, fun}, _from, state) do
    new_options = fun.(state.options)

    {:reply, :ok, %{options: new_options, table: Table.Builder.from_options(new_options)}}
  end

  def handle_call(:get_records, _from, state) do
    {:reply, state.table, state}
  end

  def handle_call({:query, query, if_info}, _from, state) do
    rr_list = Table.query(state.table, query, if_info)
    additional = Table.additional_records(state.table, rr_list, if_info)

    {:reply, %{answer: rr_list, additional: additional}, state}
  end
end
