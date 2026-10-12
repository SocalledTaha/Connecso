"""Create a compact GeoJSON asset from Natural Earth 1:110m country data.

Input files are the unmodified ne_110m_admin_0_countries shapefile set.
The output retains country names/codes and approximate label coordinates, and
uses a small Ramer-Douglas-Peucker tolerance for mobile rendering.
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path


def read_dbf(path: Path) -> list[dict[str, object]]:
    data = path.read_bytes()
    count = struct.unpack_from("<I", data, 4)[0]
    header_size = struct.unpack_from("<H", data, 8)[0]
    record_size = struct.unpack_from("<H", data, 10)[0]
    fields: list[tuple[str, int]] = []
    offset = 32
    field_offset = 1
    while data[offset] != 0x0D:
        name = data[offset : offset + 11].split(b"\0", 1)[0].decode("ascii")
        length = data[offset + 16]
        fields.append((name, field_offset))
        field_offset += length
        offset += 32

    wanted = {"ADMIN", "ISO_A2", "LABEL_X", "LABEL_Y"}
    output: list[dict[str, object]] = []
    for index in range(count):
        start = header_size + index * record_size
        record = data[start : start + record_size]
        values: dict[str, object] = {}
        for name, field_start in fields:
            if name not in wanted:
                continue
            length = next(
                data[offset + 16]
                for offset in range(32, header_size - 1, 32)
                if data[offset : offset + 11].split(b"\0", 1)[0].decode("ascii")
                == name
            )
            raw = record[field_start : field_start + length].decode(
                "ascii", errors="ignore"
            ).strip("\x00 ")
            values[name] = raw
        output.append(values)
    return output


def perpendicular_distance(point, start, end) -> float:
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    if dx == 0 and dy == 0:
        return ((point[0] - start[0]) ** 2 + (point[1] - start[1]) ** 2) ** 0.5
    return abs(dy * point[0] - dx * point[1] + end[0] * start[1] - end[1] * start[0]) / (dx * dx + dy * dy) ** 0.5


def simplify(points, tolerance: float):
    if len(points) <= 2:
        return points
    greatest = 0.0
    split_at = 0
    for index in range(1, len(points) - 1):
        distance = perpendicular_distance(points[index], points[0], points[-1])
        if distance > greatest:
            greatest = distance
            split_at = index
    if greatest > tolerance:
        left = simplify(points[: split_at + 1], tolerance)
        right = simplify(points[split_at:], tolerance)
        return left[:-1] + right
    return [points[0], points[-1]]


def read_shapes(path: Path) -> list[list[list[list[float]]]]:
    data = path.read_bytes()
    offset = 100
    shapes = []
    while offset < len(data):
        content_bytes = struct.unpack_from(">I", data, offset + 4)[0] * 2
        content = data[offset + 8 : offset + 8 + content_bytes]
        shape_type = struct.unpack_from("<I", content, 0)[0]
        if shape_type == 0:
            shapes.append([])
        elif shape_type in (5, 15, 25):
            part_count, point_count = struct.unpack_from("<II", content, 36)
            parts_offset = 44
            parts = list(struct.unpack_from(f"<{part_count}I", content, parts_offset))
            points_offset = parts_offset + part_count * 4
            all_points = [
                struct.unpack_from("<dd", content, points_offset + index * 16)
                for index in range(point_count)
            ]
            rings = []
            for part_index, start in enumerate(parts):
                end = parts[part_index + 1] if part_index + 1 < len(parts) else point_count
                points = list(all_points[start:end])
                if len(points) < 4:
                    continue
                reduced = simplify(points, 0.12)
                if reduced[0] != reduced[-1]:
                    reduced.append(reduced[0])
                rings.append([[round(x, 4), round(y, 4)] for x, y in reduced])
            shapes.append(rings)
        else:
            raise ValueError(f"Unsupported shape type {shape_type}")
        offset += 8 + content_bytes
    return shapes


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate_world_map.py INPUT_SHAPEFILE_DIR OUTPUT_GEOJSON")
    source = Path(sys.argv[1])
    target = Path(sys.argv[2])
    base = "ne_110m_admin_0_countries"
    rows = read_dbf(source / f"{base}.dbf")
    geometries = read_shapes(source / f"{base}.shp")
    if len(rows) != len(geometries):
        raise ValueError("DBF and SHP feature counts do not match")

    features = []
    for row, rings in zip(rows, geometries):
        if not rings:
            continue
        country = str(row.get("ADMIN", "")).strip()
        country_code = str(row.get("ISO_A2", "")).strip()
        label_x = float(row.get("LABEL_X", "0") or 0)
        label_y = float(row.get("LABEL_Y", "0") or 0)
        features.append(
            {
                "type": "Feature",
                "properties": {
                    "country": country,
                    "countryCode": "" if country_code == "-99" else country_code,
                    "label": [round(label_x, 4), round(label_y, 4)],
                },
                "geometry": {"type": "Polygon", "coordinates": rings},
            }
        )
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps({"type": "FeatureCollection", "features": features}, separators=(",", ":")),
        encoding="utf-8",
    )
    print(f"Wrote {len(features)} countries to {target} ({target.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
