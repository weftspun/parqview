# SPDX-License-Identifier: MIT
"""Emit one image's bytes from a Parquet shard, reading a single row group.

Memory is bounded by the row group, not the file. The row group is located from
footer statistics alone, so no data pages are decoded until the right group is
known. Bytes go to stdout; anything else to stderr, so the caller can stream the
payload without parsing.
"""
import sys
import pyarrow.parquet as pq


def main() -> int:
    path, column, target = sys.argv[1], sys.argv[2], int(sys.argv[3])
    f = pq.ParquetFile(path)
    md = f.metadata
    idx = {md.schema.column(i).name: i for i in range(md.num_columns)}
    id_col = idx.get("image_id")
    if id_col is None:
        print("no image_id column", file=sys.stderr)
        return 2

    groups = range(md.num_row_groups)
    # statistics let us skip straight to the group that can hold this id
    narrowed = []
    for i in groups:
        st = md.row_group(i).column(id_col).statistics
        if st is None:
            narrowed = list(groups)
            break
        if st.min <= target <= st.max:
            narrowed.append(i)

    for i in narrowed:
        tb = f.read_row_group(i, columns=["image_id", column])
        ids = tb.column("image_id").to_pylist()
        if target in ids:
            cell = tb.column(column)[ids.index(target)]
            val = cell.as_py()
            blob = val["bytes"] if isinstance(val, dict) else val
            sys.stdout.buffer.write(blob)
            return 0

    print("id not found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
