# SPDX-License-Identifier: MIT
"""Long-lived row-group reader, spoken to over an Erlang port.

Framing is {:packet, 4}: a 4-byte big-endian length then the payload, both ways.
Requests are JSON; responses are raw bytes, or a 4-byte-framed empty reply for
"not found", so the caller never parses the payload.

Interpreter startup and `import pyarrow` cost ~200 ms. Paying that once per
worker instead of once per request is the entire point. Open ParquetFile handles
are cached per path so the footer is parsed once, not on every fetch.
"""
import json
import struct
import sys

import pyarrow.parquet as pq

_files = {}
_stats = {}


def handle(path, column, target):
    f = _files.get(path)
    if f is None:
        f = _files[path] = pq.ParquetFile(path)
        md = f.metadata
        idx = {md.schema.column(i).name: i for i in range(md.num_columns)}
        col = idx.get("image_id")
        ranges = []
        if col is not None:
            for i in range(md.num_row_groups):
                st = md.row_group(i).column(col).statistics
                ranges.append((st.min, st.max) if st else None)
        _stats[path] = ranges

    ranges = _stats.get(path) or []
    groups = [i for i, r in enumerate(ranges) if r is None or r[0] <= target <= r[1]]
    if not ranges:
        groups = range(f.metadata.num_row_groups)

    for i in groups:
        tb = f.read_row_group(i, columns=["image_id", column])
        ids = tb.column("image_id").to_pylist()
        if target in ids:
            val = tb.column(column)[ids.index(target)].as_py()
            return val["bytes"] if isinstance(val, dict) else val
    return b""


def main():
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    while True:
        head = stdin.read(4)
        if len(head) < 4:
            return
        (n,) = struct.unpack(">I", head)
        req = json.loads(stdin.read(n))
        try:
            out = handle(req["path"], req["column"], req["id"])
        except Exception:
            out = b""
        stdout.write(struct.pack(">I", len(out)))
        stdout.write(out)
        stdout.flush()


if __name__ == "__main__":
    main()
