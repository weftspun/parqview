defmodule Parqview.Reader do
  @moduledoc """
  A pool of long-lived pyarrow workers that return one image's bytes.

  Spawning a fresh interpreter per request cost ~215 ms, essentially all of it
  interpreter startup and `import pyarrow` — roughly a thousand times the cost of
  the row-group read it was wrapping. The workers here pay that once at boot and
  then answer in the time the read actually takes.

  Each worker owns a port in `{:packet, 4}` mode, so framing is handled by the
  VM rather than by hand-rolled length parsing. Workers are stateless between
  requests apart from a cache of open Parquet handles, so any worker can serve
  any request and dispatch is round-robin.
  """
  use Supervisor

  @pool_size 4
  @timeout 30_000

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children =
      for i <- 0..(@pool_size - 1) do
        Supervisor.child_spec({Parqview.Reader.Worker, i}, id: {:reader, i})
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Bytes of `image_id` from `path`, or `:error` when absent."
  def fetch(path, column, image_id) do
    worker = rem(System.unique_integer([:positive]), @pool_size)

    GenServer.call(
      Parqview.Reader.Worker.name(worker),
      {:fetch, path, column, image_id},
      @timeout
    )
  end

  defmodule Worker do
    @moduledoc false
    use GenServer

    def name(i), do: :"parqview_reader_#{i}"
    def start_link(i), do: GenServer.start_link(__MODULE__, i, name: name(i))

    @impl true
    def init(_i) do
      Process.flag(:trap_exit, true)
      {:ok, %{port: open()}}
    end

    defp open do
      script = Application.app_dir(:parqview, ["priv", "python", "reader_worker.py"])
      python = Application.get_env(:parqview, :python, "python3")
      exe = System.find_executable(python) || raise "python not found: #{python}"

      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:args, [script]}
      ])
    end

    @impl true
    def handle_call({:fetch, path, column, id}, _from, %{port: port} = state) do
      req = Jason.encode!(%{path: path, column: column, id: id})
      Port.command(port, req)

      receive do
        {^port, {:data, ""}} -> {:reply, :error, state}
        {^port, {:data, bytes}} -> {:reply, {:ok, bytes}, state}
        {^port, {:exit_status, _}} -> {:reply, :error, %{state | port: open()}}
      after
        25_000 -> {:reply, :error, state}
      end
    end

    # a worker that dies is replaced rather than nursed: the cache it held was
    # only an optimisation
    @impl true
    def handle_info({port, {:exit_status, _}}, %{port: port} = state),
      do: {:noreply, %{state | port: open()}}

    def handle_info(_, state), do: {:noreply, state}
  end
end
