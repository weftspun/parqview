defmodule Parqview.Index do
  @moduledoc """
  Byte-offset index over a shard's image payloads.

  When a shard stores its payload column uncompressed and PLAIN-encoded, each
  image sits verbatim in the file. `priv/python/build_index.py` records
  `(image_id, offset, length)` once, and a fetch becomes a single `:file.pread` —
  no Parquet reader, no decompression, no row group, no Python.

  That is the difference between reading the bytes you asked for and reading the
  16 MB row group they happen to live in.

  The index is small — a few bytes per image — so it is read once and cached in
  `:persistent_term`, which gives lock-free concurrent reads at the cost of
  making updates expensive. Indexes do not change while a shard is being browsed.
  """
  alias Explorer.DataFrame, as: DF
  alias Explorer.Series, as: S

  @doc "Path of the index beside a shard, whether or not it exists."
  def path_for(shard), do: String.replace_suffix(shard, ".parquet", ".idx.parquet")

  @doc "True when an index has been built for this shard."
  def available?(shard), do: File.exists?(path_for(shard))

  @doc """
  `{offset, length}` for one image, or `:error`.

  Loads and caches the index on first use.
  """
  def locate(shard, image_id) do
    case Map.fetch(load(shard), image_id) do
      {:ok, loc} -> {:ok, loc}
      :error -> :error
    end
  end

  defp load(shard) do
    key = {__MODULE__, shard}

    case :persistent_term.get(key, nil) do
      nil ->
        df = shard |> path_for() |> DF.from_parquet!()

        map =
          Enum.zip([
            S.to_list(df["image_id"]),
            S.to_list(df["offset"]),
            S.to_list(df["length"])
          ])
          |> Map.new(fn {id, off, len} -> {id, {off, len}} end)

        :persistent_term.put(key, map)
        map

      map ->
        map
    end
  end

  @doc "Read one payload directly out of the shard."
  def read(shard, image_id) do
    with {:ok, {offset, length}} <- locate(shard, image_id),
         {:ok, fd} <- :file.open(shard, [:read, :binary, :raw]) do
      result = :file.pread(fd, offset, length)
      :file.close(fd)

      case result do
        {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
        _ -> :error
      end
    else
      _ -> :error
    end
  end
end
