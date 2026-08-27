defmodule Parqview.Reader do
  @moduledoc """
  Reads one image's bytes out of a Parquet shard, using DuckDB.

  DuckDB prunes row groups from Parquet statistics and pushes the projection
  down, so a fetch decodes the group holding the row rather than the file. That
  is the same work the earlier pyarrow subprocess did, minus the subprocess:
  `duckdbex` ships a precompiled NIF, so there is no Python, no port protocol,
  and no interpreter startup on the request path.

  Connections are per-caller and cheap; the prepared statement is cached per
  shard in `:persistent_term`, which keeps the plan and the Parquet footer warm
  across requests and gives lock-free concurrent reads.
  """
  use GenServer

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    {:ok, db} = Duckdbex.open()
    :persistent_term.put({__MODULE__, :db}, db)
    {:ok, %{db: db}}
  end

  defp db, do: :persistent_term.get({__MODULE__, :db})

  @doc """
  Bytes of `image_id` from `shard`, or `:error` when there is no such row.

  `column` is the payload column: `image` for the Hugging Face
  `struct<bytes, path>` layout, or a plain binary column.
  """
  def fetch(shard, column, image_id) do
    # one connection per calling process, reused across that process's requests:
    # DuckDB connections are not for concurrent use, and a LiveView or Plug
    # request process makes several fetches in a row.
    conn =
      case Process.get(:parqview_duckdb_conn) do
        nil ->
          {:ok, c} = Duckdbex.connection(db())
          Process.put(:parqview_duckdb_conn, c)
          c

        c ->
          c
      end

    # the prepared statement holds the plan and the Parquet footer, so preparing
    # it per fetch costs more than the fetch; keep one per shard per process
    key = {:parqview_duckdb_stmt, shard, column}

    stmt =
      case Process.get(key) do
        nil ->
          {:ok, s} = Duckdbex.prepare_statement(conn, sql(shard, column))
          Process.put(key, s)
          s

        s ->
          s
      end

    case Duckdbex.execute_statement(stmt, [image_id]) do
      {:ok, result} ->
        case Duckdbex.fetch_all(result) do
          [[bytes]] when is_binary(bytes) -> {:ok, bytes}
          _ -> :error
        end

      {:error, _} ->
        :error
    end
  end

  # `image.bytes` reaches into the struct so only the payload field is read;
  # a plain binary column is selected directly.
  defp sql(shard, "image"),
    do: "SELECT image.bytes FROM read_parquet(#{literal(shard)}) WHERE image_id = $1"

  defp sql(shard, column),
    do: "SELECT #{quoted(column)} FROM read_parquet(#{literal(shard)}) WHERE image_id = $1"

  # the path is interpolated because read_parquet takes a constant, so it is
  # escaped as a SQL string literal rather than trusted
  defp literal(path), do: "'" <> String.replace(path, "'", "''") <> "'"
  defp quoted(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""
end
