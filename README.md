# parqview

A local web viewer for directories of Parquet files, in Elixir. Browse relations
as paged tables; browse embedded images as a thumbnail grid. Ships as a single
self-contained binary per platform via [Burrito](https://github.com/burrito-elixir/burrito) — no Erlang, Elixir, or Python
install on the target machine.

Built because the good Parquet tools split along an awkward line: DuckDB and Tad
are excellent at columns and joins but show an image column as an opaque blob,
while image-first tools like FiftyOne want a directory of files, not Parquet.
Datasets that embed image bytes — the layout Hugging Face `datasets` writes —
fall between them.

## What it does

- Lists every `*.parquet` under a directory, recursively, with row counts and
  file sizes read from the footer.
- Pages through any relation as a table.
- Renders any relation carrying an `image` column as a lazy-loading thumbnail
  grid, decoding JPEG/PNG/GIF from the embedded bytes.
- Understands both the Hugging Face `struct<bytes, path>` Image layout and a
  plain `image_bytes` binary column.

## Running

```sh
PARQVIEW_DIR=/path/to/parquet PORT=4000 ./parqview start
```

Then open <http://localhost:4000>. From source:

```sh
mix deps.get
PARQVIEW_DIR=/path/to/parquet mix phx.server
```

## Building the binaries

```sh
mix rustler_precompiled.download Explorer.PolarsBackend.Native --all
MIX_ENV=prod mix assets.deploy
for t in macos_arm macos_x86 linux_x86 windows_x86; do
  MIX_ENV=prod BURRITO_TARGET=$t mix release --overwrite
done
```

Targets land in `burrito_out/`.

### Why the NIF download step matters

Explorer's Polars backend is a Rust NIF delivered by `rustler_precompiled`,
which fetches exactly one artefact: the one matching the **build host**. Burrito
will happily wrap that release for four targets and hand you three binaries that
crash on boot with a load error.

`Parqview.ReleaseSteps.swap_nif/1` runs between `:assemble` and `Burrito.wrap/1`
and replaces the bundled NIF with the one for the target being built, taken from
the `rustler_precompiled` cache — which is what the `--all` download populates.
Without that download the build fails loudly rather than shipping a broken
binary.

## Known issues

**Burrito 1.6.0 on OTP 29 produces binaries that do not boot.** The
self-extracting payload arrives incomplete — in our testing, sometimes missing
`erts-*/bin/erl`, sometimes the whole ERTS directory, sometimes application
modules such as HPAX. The extracted tree can be repaired by hand from
`_build/prod/rel/<app>/`, after which it runs correctly, so the release itself is
sound and the fault is in Burrito's packing or extraction. On OTP 27/28 this
does not occur. Until it is resolved, `mix release` without Burrito produces a
working release, and per-platform CI builds are the reliable path to binaries.

**`Dataset.image_bytes/3` loads the whole relation to fetch one image.** Fine for
shards up to a few hundred MB; against 1.5 GB shards a page of sixty thumbnails
will try to allocate far more memory than you have. Fixing this needs a
row-group-targeted read rather than `DF.from_parquet!/1`. Point it at modest
shards until then.

## Error handling

The app does not validate request input. A bad relation name or a non-numeric id
raises `Parqview.NotFoundError` and the process dies — let it crash. That
exception carries `plug_status: 404` so `Plug.Exception` reports the crash as the
client error it is, rather than a 500 implying the server is at fault. Defensive
`with` chains were deliberately removed in favour of this.

## Testing

`test/pw_test.py` is a Playwright functional suite: sidebar, table rendering,
thumbnail decode in a real browser, pagination. `test/pw_adversarial.py` is a
hostile suite: path traversal, malformed ids, unknown relations, concurrent
reads, and LiveView events the UI would never generate.

```sh
pip install playwright requests && playwright install chromium
python test/pw_test.py http://localhost:4000
python test/pw_adversarial.py http://localhost:4000
```

The functional suite asserts `liveSocket.isConnected()`, not the presence of
`[data-phx-main]`. The attribute is in the static HTML whether or not the socket
connects, so asserting on it passes while every click is silently inert — which
is exactly the bug it failed to catch during development.

## Licence

MIT.
