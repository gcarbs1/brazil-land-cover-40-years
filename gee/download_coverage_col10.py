"""Download the reduced MapBiomas Collection 10 maps through Earth Engine.

Same computation as gee/export_coverage_col10.js, but fetched directly with
`ee.data.computePixels` in tiles, so no Google Drive step is needed.

    pip install earthengine-api
    gcloud auth application-default login \
        --scopes=https://www.googleapis.com/auth/earthengine,https://www.googleapis.com/auth/cloud-platform
    python gee/download_coverage_col10.py --project <cloud-project-id>

Writes data/raw/mapbiomas/gee_tiles_<year>/tile_<row>_<col>.tif, two bands:
  1 group     majority group in blocks of 34 x 34 pixels of 30 m (0 = no data)
  2 solar_px  number of 30 m photovoltaic pixels in the block
With --dem it also fetches data/raw/mapbiomas/gee_tiles_dem/, the SRTM
elevation (CGIAR SRTM 90 m v4, metres) on the same grid, used only for the
hillshade under the maps.

R/land_cover_1985_2024.R mosaics the tiles.
"""

import argparse
import concurrent.futures as cf
import math
import pathlib
import time

import ee

ASSET = "projects/mapbiomas-public/assets/brazil/lulc/v1"
FROM_CLASSES = [3, 4, 5, 6, 49, 11, 12, 32, 29, 50,
                15,
                39, 20, 40, 62, 41, 46, 47, 35, 48, 9,
                21,
                24,
                75,
                23, 30, 25, 33, 31, 27]
TO_GROUPS = [1] * 10 + [2] + [3] * 10 + [4] + [5] + [6] + [7] * 6

PIXEL = 0.000269494585236          # MapBiomas 30 m pixel, in degrees
FACT = 34                          # 34 x 34 pixels = about 1 km
STEP = PIXEL * FACT
WEST, EAST, SOUTH, NORTH = -74.0, -28.5, -34.0, 5.5
TILE = 256


def reduced_image(year):
    classes = (ee.ImageCollection(ASSET)
               .filter(ee.Filter.eq("collection_id", 10.0))
               .filter(ee.Filter.eq("version", "v1"))
               .filter(ee.Filter.eq("year", year))
               .first()
               .select("classification"))
    groups = classes.remap(FROM_CLASSES, TO_GROUPS).rename("group")
    majority = groups.reduceResolution(reducer=ee.Reducer.mode(), maxPixels=2048)
    solar = (classes.eq(75).rename("solar_px")
             .reduceResolution(reducer=ee.Reducer.sum().unweighted(),
                               maxPixels=2048))
    return majority.addBands(solar).unmask(0).toInt32()


def dem_image():
    # Mean elevation of the SRTM pixels in each cell.
    return (ee.Image("CGIAR/SRTM90_V4").select("elevation")
            .reduceResolution(reducer=ee.Reducer.mean(), maxPixels=2048)
            .unmask(0).toInt16())


def fetch_all(image, label, out_dir, tiles, n_rows, n_cols, workers):
    out_dir.mkdir(parents=True, exist_ok=True)
    todo = [(r, c) for r, c in tiles
            if not (out_dir / f"tile_{r:02d}_{c:02d}.tif").exists()]
    print(f"{label}: {len(todo)} of {len(tiles)} tiles to fetch", flush=True)
    with cf.ThreadPoolExecutor(workers) as pool:
        jobs = [pool.submit(fetch, image, r, c, n_rows, n_cols,
                            out_dir / f"tile_{r:02d}_{c:02d}.tif")
                for r, c in todo]
        for i, job in enumerate(cf.as_completed(jobs), 1):
            job.result()
            if i % 25 == 0:
                print(f"{label}: {i} of {len(todo)}", flush=True)
    print(f"{label}: done", flush=True)


def fetch(image, row, col, n_rows, n_cols, out_file, attempts=4):
    width = min(TILE, n_cols - col * TILE)
    height = min(TILE, n_rows - row * TILE)
    request = {
        "expression": image,
        "fileFormat": "GEO_TIFF",
        "grid": {
            "dimensions": {"width": width, "height": height},
            "affineTransform": {
                "scaleX": STEP, "shearX": 0, "translateX": WEST + col * TILE * STEP,
                "shearY": 0, "scaleY": -STEP, "translateY": NORTH - row * TILE * STEP,
            },
            "crsCode": "EPSG:4326",
        },
    }
    for attempt in range(attempts):
        try:
            out_file.write_bytes(ee.data.computePixels(request))
            return out_file
        except Exception as error:  # quota or transient errors: back off
            if attempt == attempts - 1:
                raise
            time.sleep(5 * 2 ** attempt)
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--years", nargs="+", type=int, default=[1985, 2024])
    parser.add_argument("--out", default="data/raw/mapbiomas")
    parser.add_argument("--workers", type=int, default=12)
    parser.add_argument("--dem", action="store_true",
                        help="also fetch SRTM elevation for the hillshade")
    args = parser.parse_args()

    ee.Initialize(project=args.project)
    n_cols = math.ceil((EAST - WEST) / STEP)
    n_rows = math.ceil((NORTH - SOUTH) / STEP)
    tiles = [(r, c) for r in range(math.ceil(n_rows / TILE))
             for c in range(math.ceil(n_cols / TILE))]

    out = pathlib.Path(args.out)
    for year in args.years:
        fetch_all(reduced_image(year), str(year), out / f"gee_tiles_{year}",
                  tiles, n_rows, n_cols, args.workers)
    if args.dem:
        fetch_all(dem_image(), "dem", out / "gee_tiles_dem",
                  tiles, n_rows, n_cols, args.workers)

if __name__ == "__main__":
    main()
