defmodule Parqview.Dataset do
  @moduledoc """
  Reads a directory of Parquet relations and the image shards beside them.

  Everything is lazy. Relation frames are opened on demand and paged with
  `slice/3` rather than materialised, so a shard of embedded images is never
  fully loaded to show sixty thumbnails.
  """
  alias Explorer.DataFrame, as: DF
  alias Explorer.Series, as: S
  # DF.filter/2 is a macro: the query expression is compiled, which is what lets
  # Polars push the predicate down into the Parquet reader.
  require Explorer.DataFrame

  @doc "Directory currently being browsed."
  def dir, do: Application.get_env(:parqview, :dir, File.cwd!())

  @doc "Relation name -> {row_count, byte_size}, cheap: read from the footer only."
  def relations(dir \\ dir()) do
    dir
    |> parquet_files()
    |> Enum.map(fn path ->
      name = Path.basename(path, ".parquet")
      {name, rows(path), File.stat!(path).size}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp parquet_files(dir) do
    [Path.join([dir, "**", "*.parquet"])]
    |> Enum.flat_map(&Path.wildcard/1)
  end

  @doc "Row count, read from the file footer where the backend allows it."
  def rows(path) do
    path |> DF.from_parquet!(lazy: true) |> DF.n_rows()
  rescue
    _ -> path |> DF.from_parquet!() |> DF.n_rows()
  end

  @doc """
  Absolute path of a relation. Raises `Parqview.NotFoundError` when there is no
  such relation, so callers never have to check — the crash carries a 404.
  """
  def path_for(name, dir \\ dir()) do
    key = {__MODULE__, :path, dir, name}

    case :persistent_term.get(key, nil) do
      nil ->
        path = resolve(name, dir)
        :persistent_term.put(key, path)
        path

      path ->
        path
    end
  end

  defp resolve(name, dir) do
    dir
    |> parquet_files()
    |> Enum.find(&(Path.basename(&1, ".parquet") == name))
    |> case do
      nil -> raise Parqview.NotFoundError, message: "no relation #{inspect(name)}"
      path -> path
    end
  end

  @doc "A page of a relation as {columns, rows-as-lists}, images elided."
  def page(name, offset, limit, dir \\ dir()) do
    path = path_for(name, dir)
    cols = path |> DF.from_parquet!(max_rows: 1) |> DF.names()
           |> Enum.reject(&(&1 in ["image", "image_bytes"]))
    df = DF.from_parquet!(path, columns: cols)
    slice = DF.slice(df, offset, limit)

    rows =
      cols
      |> Enum.map(&(slice[&1] |> S.to_list() |> Enum.map(fn v -> render(v) end)))
      |> Enum.zip_with(& &1)

    {cols, rows, DF.n_rows(df)}
  end

  defp render(v) when is_binary(v) and byte_size(v) > 120, do: binary_part(v, 0, 120) <> "…"
  defp render(v) when is_float(v), do: Float.round(v, 6)
  defp render(v), do: v

  @doc """
  True when a relation embeds image bytes.

  Reads a single row rather than a lazy frame: the lazy path is backend
  dependent and silently unavailable in a release, which is exactly the kind of
  difference a `rescue` turns into a wrong answer instead of a crash.
  """
  def image_relation?(name, dir \\ dir()) do
    cols = name |> path_for(dir) |> DF.from_parquet!(max_rows: 1) |> DF.names()
    "image" in cols or "image_bytes" in cols
  end

  @doc """
  A page of thumbnails as `{image_id, label, score}`, bytes fetched separately.

  `score` is an optional caption value: the first float column in the relation
  other than the id. Datasets often carry a per-image number worth seeing next to
  the thumbnail — a confidence, a rating, a distance — and which column that is
  varies, so it is discovered rather than named.
  """
  def image_page(name, offset, limit, dir \\ dir()) do
    path = path_for(name, dir)
    all = path |> DF.from_parquet!(max_rows: 1) |> DF.names()
    # project away the payload: a page of captions must not decode any image
    wanted = Enum.reject(all, &(&1 in ["image", "image_bytes"]))
    df = DF.from_parquet!(path, columns: wanted)
    slice = DF.slice(df, offset, limit)
    names = DF.names(df)

    ids = slice["image_id"] |> S.to_list()
    paths = if "rel_path" in names, do: S.to_list(slice["rel_path"]), else: Enum.map(ids, &"##{&1}")

    scores =
      case score_column(df, names) do
        nil -> Enum.map(ids, fn _ -> nil end)
        col -> S.to_list(slice[col])
      end

    {Enum.zip([ids, paths, scores]), DF.n_rows(df)}
  end

  # first float column that is not an identifier, used as the thumbnail caption
  defp score_column(df, names) do
    Enum.find(names, fn n ->
      n not in ["image_id", "rel_path", "sha256", "image", "image_bytes"] and
        match?({:f, _}, S.dtype(df[n]))
    end)
  end

  @doc """
  Raw bytes of one embedded image, read through DuckDB.

  Memory is bounded by the row group holding the row, not by the file: DuckDB
  prunes row groups from Parquet statistics and pushes the projection down, so
  the payload of non-matching rows is never decoded.

  The naive alternative — `DF.from_parquet!/1`, find the row, take the cell —
  peaked at 4.8 GB for eight fetches from a 1.49 GB shard. Explorer's
  `lazy: true` measured no better, because the scan is not streamed and the
  predicate is not pushed into the reader. Worse, `Series.to_list/1` on a
  multi-chunk struct column panics the Polars NIF, and a NIF panic takes down the
  VM rather than raising.

  Row-group size is therefore the memory ceiling. Size groups by bytes, not rows:
  16 rows of 500 KB thumbnails is 8 MB, but 16 rows of 15 MB originals is 240 MB.
  """
  def image_bytes(name, image_id, dir \\ dir()) do
    path = path_for(name, dir)
    col = payload_column(path)

    case Parqview.Reader.fetch(path, col, image_id) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> raise Parqview.NotFoundError, message: "no image #{image_id} in #{name}"
    end
  end

  defp payload_column(path) do
    names = path |> DF.from_parquet!(max_rows: 1) |> DF.names()

    cond do
      "image" in names -> "image"
      "image_bytes" in names -> "image_bytes"
      true -> raise Parqview.NotFoundError, message: "#{Path.basename(path)} carries no image column"
    end
  end
end
