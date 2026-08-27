# SPDX-License-Identifier: MIT
"""Build a byte-offset index for the image payloads in a Parquet shard.

When the payload column is stored uncompressed and PLAIN-encoded, each value
sits verbatim in the file as [4-byte LE length][bytes]. An index of
(image_id, offset, length) therefore turns a fetch into a single pread — no
Parquet reader, no decompression, no row group.

Values appear in file order, so the scan carries a forward cursor and never
rescans; page headers between values are skipped by searching for the next
length prefix rather than by parsing Thrift.

Written once per shard. Emits <shard>.idx.parquet beside it.
"""
import mmap
import struct
import sys

import pyarrow as pa
import pyarrow.parquet as pq


def payload_uncompressed(md, name="image"):
    for i in range(md.num_columns):
        path = md.schema.column(i).path
        if path in (f"{name}.bytes", name):
            return md.row_group(0).column(i).compression in ("UNCOMPRESSED", None)
    return False


def main() -> int:
    path = sys.argv[1]
    col = sys.argv[2] if len(sys.argv) > 2 else "image"
    pf = pq.ParquetFile(path)
    md = pf.metadata

    if not payload_uncompressed(md, col):
        print("payload column is compressed; index not applicable", file=sys.stderr)
        return 2

    ids, offsets, lengths = [], [], []
    with open(path, "rb") as fh:
        mm = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)
        cursor = 0
        for rg in range(md.num_row_groups):
            tb = pf.read_row_group(rg, columns=["image_id", col])
            rg_ids = tb.column("image_id").to_pylist()
            vals = tb.column(col).to_pylist()
            for image_id, v in zip(rg_ids, vals):
                blob = v["bytes"] if isinstance(v, dict) else v
                n = len(blob)
                needle = struct.pack("<I", n) + blob[:24]
                at = mm.find(needle, cursor)
                if at < 0:
                    print(f"value for id {image_id} not located", file=sys.stderr)
                    return 3
                ids.append(image_id)
                offsets.append(at + 4)
                lengths.append(n)
                cursor = at + 4 + n
        mm.close()

    out = path.rsplit(".parquet", 1)[0] + ".idx.parquet"
    tbl = pa.table(
        {
            "image_id": pa.array(ids, pa.int32()),
            "offset": pa.array(offsets, pa.int64()),
            "length": pa.array(lengths, pa.int32()),
        },
        schema=pa.schema(
            [
                pa.field("image_id", pa.int32(), nullable=False),
                pa.field("offset", pa.int64(), nullable=False),
                pa.field("length", pa.int32(), nullable=False),
            ]
        ),
    )
    pq.write_table(tbl, out, compression="zstd", compression_level=19)
    print(f"indexed {len(ids)} values -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
