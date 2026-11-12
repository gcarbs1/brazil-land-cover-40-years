// Alternative input for R/land_cover_1985_2024.R, for when the 30 m GeoTIFFs
// (brazil_coverage_1985.tif and brazil_coverage_2024.tif) cannot be
// downloaded. Paste into the Earth Engine Code Editor and run the two tasks.
//
// Output, one GeoTIFF per year in the Drive folder `mapbiomas`:
//   col10_mode_<year>.tif
//     band 1 `group`    majority group in blocks of 34 x 34 pixels of 30 m
//     band 2 `solar_px` number of 30 m photovoltaic pixels in the block
// Copy both files to data/raw/mapbiomas/ and run the R script.
//
// The group codes follow `groups` in the R script:
//   1 native vegetation, 2 pasture, 3 agriculture and forest plantation,
//   4 mosaic of uses, 5 urban area, 6 photovoltaic, 7 other.

var collection = ee.ImageCollection('projects/mapbiomas-public/assets/brazil/lulc/v1')
  .filter(ee.Filter.eq('collection_id', 10.0))
  .filter(ee.Filter.eq('version', 'v1'));

var fromClasses = [3, 4, 5, 6, 49, 11, 12, 32, 29, 50,
                   15,
                   39, 20, 40, 62, 41, 46, 47, 35, 48, 9,
                   21,
                   24,
                   75,
                   23, 30, 25, 33, 31, 27];
var toGroups    = [1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                   2,
                   3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
                   4,
                   5,
                   6,
                   7, 7, 7, 7, 7, 7];

var pixel = 0.000269494585236;   // MapBiomas 30 m pixel, in degrees
var fact = 34;
var west = -74.0, north = 5.5;
var transform = [pixel * fact, 0, west, 0, -pixel * fact, north];
var region = ee.Geometry.Rectangle([west, -34.0, -28.5, north], null, false);

[1985, 2024].forEach(function (year) {
  var classes = collection.filter(ee.Filter.eq('year', year)).first()
    .select('classification');
  var groups = classes.remap(fromClasses, toGroups).rename('group');
  var majority = groups
    .reduceResolution({reducer: ee.Reducer.mode(), maxPixels: 2048})
    .reproject({crs: 'EPSG:4326', crsTransform: transform});
  var solar = classes.eq(75).rename('solar_px')
    .reduceResolution({reducer: ee.Reducer.sum().unweighted(), maxPixels: 2048})
    .reproject({crs: 'EPSG:4326', crsTransform: transform});
  Export.image.toDrive({
    image: majority.addBands(solar).toInt32(),
    description: 'col10_mode_' + year,
    folder: 'mapbiomas',
    fileNamePrefix: 'col10_mode_' + year,
    region: region,
    crs: 'EPSG:4326',
    crsTransform: transform,
    maxPixels: 1e10
  });
});
