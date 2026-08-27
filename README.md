# parqview

A local web viewer for directories of Parquet files, in Elixir. Browse relations
as paged tables; browse embedded images as a thumbnail grid. Ships as a standard
Elixir release with ERTS bundled — no Erlang, Elixir, or Python install on the
target machine.

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
PARQVIEW_DIR=/path/to/parquet PORT=4000 bin/parqview start
```

Then open <http://localhost:4000>. From source:

```sh
mix deps.get
PARQVIEW_DIR=/path/to/parquet mix phx.server
```

## Building a release

```sh
mix deps.get
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

That produces `_build/prod/rel/parqview/` and a tarball
`_build/prod/parqview-<vsn>.tar.gz`. The tarball is self-contained: extract it
anywhere and run `bin/parqview start`. ERTS is included, so the target machine
needs no BEAM install.

### Releases are per-platform, not cross-compiled

Explorer's Polars backend is a Rust NIF delivered by `rustler_precompiled`,
which fetches exactly one artefact: the one matching the build host. A release
built on macOS will not run on Linux, and no amount of packaging changes that.
Build each platform on its own runner — `.github/workflows/release.yml` does
this across Linux, macOS arm64/x86_64 and Windows, smoke-tests each tarball for a
bundled ERTS, and attaches them to a tagged release.

An earlier version of this project used Burrito to produce single-file
self-extracting binaries and cross-compile all four targets from one host. It was
removed. On OTP 29 the extracted payload arrived incomplete and
non-deterministically — one run missing `erts-*/bin/erl`, the next missing the
whole ERTS directory, another missing application modules — and the cross-target
NIF problem above needed a bespoke release step to work around. A standard
release plus a CI matrix is less clever and actually works.

## Known issues

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
