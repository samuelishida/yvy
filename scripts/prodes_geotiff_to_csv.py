#!/usr/bin/env python3
"""Convert PRODES GeoTIFF raster to lon,lat,value CSV for Yvy ingestion.

Usage:
    python scripts/prodes_geotiff_to_csv.py [--target N] [--tif PATH] [--pixel-count N]

Options:
    --target N        Approximate number of output points (default: 200000)
    --tif PATH        Path to GeoTIFF (auto-detected if omitted)
    --pixel-count N   Skip pass 1 and use this known pixel total (speeds re-runs)

Requires: rasterio, numpy
    pip install rasterio
"""

import sys
import os
import argparse

try:
    import numpy as np
    import rasterio
    from rasterio.crs import CRS
    from pyproj import Transformer
except ImportError as e:
    print(f"ERROR: Missing dependency - {e}", file=sys.stderr)
    print("Install with: pip install rasterio", file=sys.stderr)
    sys.exit(1)

# PRODES pixel values to ingest:
#   1-24  = deforestation in year 2000+N (d2000 ... d2024)
#   50-64 = residual/regrowth (r2010 ... r2024)
INGEST_VALUES = np.array(sorted(set(range(1, 25)) | set(range(50, 65))), dtype=np.uint8)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", type=int, default=200_000, help="Target output point count")
    parser.add_argument("--tif", default=None, help="Path to input GeoTIFF")
    parser.add_argument("--pixel-count", type=int, default=None, help="Known total qualifying pixel count (skip pass 1)")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)
    data_dir = os.path.join(project_dir, "backend-lua", "data", "prodes_brasil_2024_v20260407")
    base = "prodes_brasil_2024_v20260407"

    tif_path = args.tif or os.path.join(data_dir, f"{base}.tif")
    csv_path = os.path.join(data_dir, f"{base}.csv")

    if not os.path.exists(tif_path):
        print(f"ERROR: GeoTIFF not found: {tif_path}", file=sys.stderr)
        sys.exit(1)

    print(f"Input:  {tif_path} ({os.path.getsize(tif_path) / 1e6:.0f} MB)")
    print(f"Output: {csv_path}")

    with rasterio.open(tif_path) as src:
        print(f"Size:   {src.width} x {src.height} px")
        print(f"CRS:    {src.crs}")

        # Reprojection to WGS84 if needed (PRODES usually EPSG:4674 ~ WGS84)
        wgs84 = CRS.from_epsg(4326)
        src_epsg = src.crs.to_epsg() if src.crs else None
        need_reproject = src_epsg not in (4326, 4674, None)
        transformer = None
        if need_reproject:
            transformer = Transformer.from_crs(src.crs, wgs84, always_xy=True)
            print(f"Reproject: EPSG:{src_epsg} -> WGS84")

        # Pixel->geo transform coefficients (read once)
        ox = src.transform.c   # origin x (lon of top-left pixel corner)
        pw = src.transform.a   # pixel width in x
        oy = src.transform.f   # origin y (lat of top-left pixel corner)
        ph = src.transform.e   # pixel height in y (negative)

        # Pass 1: count qualifying pixels (skip if known)
        if args.pixel_count:
            total_pixels = args.pixel_count
            print(f"Pass 1/2: skipped (--pixel-count {total_pixels:,})")
        else:
            print("\nPass 1/2: counting deforestation pixels...")
            total_pixels = 0
            block_count = 0
            for _, window in src.block_windows(1):
                block = src.read(1, window=window)
                total_pixels += int(np.isin(block, INGEST_VALUES).sum())
                block_count += 1
                if block_count % 500 == 0:
                    print(f"  {block_count} blocks, {total_pixels:,} pixels so far...", flush=True)
            print(f"Total qualifying pixels: {total_pixels:,}")
            print(f"Re-run with --pixel-count {total_pixels} to skip this step next time.")

        if total_pixels == 0:
            print("No deforestation pixels found.", file=sys.stderr)
            sys.exit(1)

        skip_n = max(1, total_pixels // args.target)
        expected = total_pixels // skip_n
        print(f"Sample 1 in {skip_n} -> ~{expected:,} output points\n")

        # Pass 2: vectorized write using numpy — no Python loop per pixel
        print("Pass 2/2: writing CSV...")
        pixel_idx = 0
        written = 0
        block_count = 0

        with open(csv_path, "w", buffering=1 << 20) as out:
            out.write("lon,lat,value\n")

            for _, window in src.block_windows(1):
                block = src.read(1, window=window)
                block_count += 1
                if block_count % 2000 == 0:
                    print(f"  block {block_count}, written {written:,}...", flush=True)

                block_rows, block_cols = np.where(np.isin(block, INGEST_VALUES))
                n_qualify = len(block_rows)
                if n_qualify == 0:
                    continue

                # Select every skip_n-th pixel globally using vectorized index arithmetic
                # pixel_idx is the running counter BEFORE this block's pixels
                first_local = skip_n - (pixel_idx % skip_n)
                if first_local > n_qualify:
                    pixel_idx += n_qualify
                    continue

                take_local = np.arange(first_local - 1, n_qualify, skip_n)
                sel_rows = block_rows[take_local]
                sel_cols = block_cols[take_local]
                sel_vals = block[sel_rows, sel_cols]

                ds_rows = window.row_off + sel_rows
                ds_cols = window.col_off + sel_cols

                lons = ox + (ds_cols.astype(np.float64) + 0.5) * pw
                lats = oy + (ds_rows.astype(np.float64) + 0.5) * ph

                if transformer:
                    lons, lats = transformer.transform(lons, lats)

                # Batch write
                for lon_v, lat_v, val in zip(lons.tolist(), lats.tolist(), sel_vals.tolist()):
                    out.write(f"{lon_v:.6f},{lat_v:.6f},{val}\n")
                written += len(take_local)
                pixel_idx += n_qualify

    print(f"\nDone. {written:,} records -> {csv_path}")
    print(f"File size: {os.path.getsize(csv_path) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
