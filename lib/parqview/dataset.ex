defmodule Parqview.Dataset do
  @moduledoc """
  Reads a directory of Parquet relations and the image shards beside them.

  Everything is lazy. Relation frames are opened on demand and paged with
  `slice/3` rather than materialised, so a shard of embedded images is never
  fully loaded to show sixty thumbnails.
  """
  alias Explorer.DataFrame, as: DF
  alias Explorer.Series, as: S

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
    df = name |> path_for(dir) |> DF.from_parquet!()
    cols = DF.names(df) |> Enum.reject(&(&1 == "image"))
    slice = DF.slice(df, offset, limit) |> DF.select(cols)

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
    df = name |> path_for(dir) |> DF.from_parquet!()
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

  @doc "Raw bytes of one embedded image, looked up by id within a relation."
  def image_bytes(name, image_id, dir \\ dir()) do
    df = name |> path_for(dir) |> DF.from_parquet!()
    idx = df["image_id"] |> S.to_list() |> Enum.find_index(&(&1 == image_id))

    case idx do
      nil -> raise Parqview.NotFoundError, message: "no image #{image_id} in #{name}"
      i ->
        case df["image"] |> S.to_list() |> Enum.at(i) do
          %{"bytes" => b} -> {:ok, b}
          b when is_binary(b) -> {:ok, b}
          _ -> :error
        end
    end
  end
end
