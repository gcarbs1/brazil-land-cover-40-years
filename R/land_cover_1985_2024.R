# O Brasil em 40 anos: do que é feito o território
#
# Editorial poster (4:5, 300 dpi) comparing land cover and land use in Brazil
# in 1985 and 2024, from MapBiomas Collection 10.
#
# One script, run from the project root:
#
#   Rscript R/land_cover_1985_2024.R
#
# | step | what it does                                                       |
# |------|--------------------------------------------------------------------|
# | 1    | downloads the official Collection 10 statistics (biome x state)    |
# | 2    | writes the class-to-group mapping, one row per MapBiomas class     |
# | 3    | computes areas per group, year and biome from the 30 m statistics  |
# | 4    | validates the figures against the published MapBiomas numbers      |
# | 5    | resamples the 30 m annual maps to the poster resolution            |
# | 6    | draws and exports the poster                                       |
#
# Every area shown on the poster comes from step 3 (official 30 m
# statistics). The resampled rasters of step 5 are used only to draw the maps;
# their areas are reported in the validation table to show the effect of
# resampling, never printed on the poster.


# 0. Configuration -------------------------------------------------------------

# Paths are relative to the project root. Change them here if needed.
project_dir   <- "."
raw_dir       <- file.path(project_dir, "data", "raw", "mapbiomas")
processed_dir <- file.path(project_dir, "data", "processed")
viz_dir       <- file.path(project_dir, "viz")
font_dir      <- file.path(project_dir, "assets", "fonts")

# Official statistics: area (ha) per class, biome and state, 1985 to 2024,
# Collection 10 (August 2025). Downloaded once, then read from disk.
stats_url  <- paste0(
  "https://brasil.mapbiomas.org/wp-content/uploads/sites/3/2025/08/",
  "MAPBIOMAS_BRAZIL-COL.10-BIOME_STATE.xlsx"
)
stats_file <- file.path(raw_dir, "MAPBIOMAS_BRAZIL-COL.10-BIOME_STATE.xlsx")

# Annual 30 m maps of Collection 10 (one GeoTIFF per year, band = class code).
# The public bucket refuses anonymous downloads, so the files must be placed in
# `raw_dir` by hand. Two inputs are accepted, checked in this order:
#   a) the official 30 m mosaics, `brazil_coverage_<year>.tif`;
#   b) the reduced exports written by `gee/export_coverage_col10.js`
#      (`col10_mode_<year>.tif` and `col10_solar_fraction_2024.tif`).
coverage_url_template <- paste0(
  "https://storage.googleapis.com/mapbiomas-public/initiatives/brasil/",
  "collection_10/lulc/coverage/brazil_coverage_{year}.tif"
)
years <- c(1985L, 2024L)

# Map resolution. Brazil is about 4,400 km wide and each panel is about 2,000
# pixels wide at 300 dpi, so a 1 km cell is finer than the printed pixel.
# The 30 m classes are resampled by majority (mode): each 1 km cell takes the
# most frequent class among its ~1,100 source pixels.
map_resolution_m <- 1000
map_crs <- paste(
  "+proj=aea +lat_0=-12 +lon_0=-54 +lat_1=-2 +lat_2=-22",
  "+x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs"
)  # Albers equal-area conic for Brazil (IBGE parameters)

# Poster size: 4:5 portrait.
poster_width_cm  <- 32
poster_height_cm <- 40
poster_dpi       <- 300
poster_file      <- file.path(viz_dir, "brasil_cobertura_1985_2024.png")


# Packages ---------------------------------------------------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(readxl)
  library(stringr)
  library(purrr)
})

for (directory in c(raw_dir, processed_dir, viz_dir)) {
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
}

processed_path <- function(name) file.path(processed_dir, name)


# 1. Official statistics -------------------------------------------------------

if (!file.exists(stats_file)) {
  message("Downloading ", stats_url)
  options(timeout = max(600, getOption("timeout")))
  download.file(stats_url, stats_file, mode = "wb", quiet = TRUE)
}

coverage_raw <- read_excel(stats_file, sheet = "COVERAGE_10")
transition_raw <- read_excel(stats_file, sheet = "TRANSITION_10")

# Year columns come as "1985.0" ... "2024.0".
names(coverage_raw) <- str_remove(names(coverage_raw), "\\.0$")

coverage <- coverage_raw |>
  select(biome, state, class, class_level_0, all_of(as.character(years))) |>
  pivot_longer(all_of(as.character(years)), names_to = "year",
               values_to = "area_ha") |>
  mutate(year = as.integer(year), class = as.integer(class),
         area_ha = coalesce(area_ha, 0))

brazil_area_ha <- coverage |>
  filter(year == years[1]) |>
  summarise(area_ha = sum(area_ha)) |>
  pull(area_ha)


# 2. Class mapping -------------------------------------------------------------

# The 30 classes of Collection 10, aggregated into six groups plus solar.
# `mapbiomas_level_0` is MapBiomas' own Natural / Antropic flag; it defines the
# "natural areas" used in the published 111.7 Mha figure.
groups <- tribble(
  ~group_id,      ~group_pt,                               ~group_order,
  "native",       "Vegetação nativa",                      1L,
  "pasture",      "Pastagem",                              2L,
  "agriculture",  "Agricultura e silvicultura",            3L,
  "mosaic",       "Mosaico de usos",                       4L,
  "urban",        "Área urbana",                           5L,
  "solar",        "Usinas fotovoltaicas",                  6L,
  "other",        "Outros (água, mineração e demais)",     7L
)

class_map <- tribble(
  ~class_id, ~class_pt,                              ~class_en,                         ~group_id,
  3L,  "Formação florestal",                         "Forest formation",                "native",
  4L,  "Formação savânica",                          "Savanna formation",               "native",
  5L,  "Mangue",                                     "Mangrove",                        "native",
  6L,  "Floresta alagável",                          "Floodable forest",                "native",
  49L, "Restinga arbórea",                           "Wooded sandbank vegetation",      "native",
  11L, "Campo alagado e área pantanosa",             "Wetland",                         "native",
  12L, "Formação campestre",                         "Grassland",                       "native",
  32L, "Apicum",                                     "Hypersaline tidal flat",          "native",
  29L, "Afloramento rochoso",                        "Rocky outcrop",                   "native",
  50L, "Restinga herbácea",                          "Herbaceous sandbank vegetation",  "native",
  15L, "Pastagem",                                   "Pasture",                         "pasture",
  39L, "Soja",                                       "Soybean",                         "agriculture",
  20L, "Cana",                                       "Sugar cane",                      "agriculture",
  40L, "Arroz",                                      "Rice",                            "agriculture",
  62L, "Algodão",                                    "Cotton",                          "agriculture",
  41L, "Outras lavouras temporárias",                "Other temporary crops",           "agriculture",
  46L, "Café",                                       "Coffee",                          "agriculture",
  47L, "Citrus",                                     "Citrus",                          "agriculture",
  35L, "Dendê",                                      "Palm oil",                        "agriculture",
  48L, "Outras lavouras perenes",                    "Other perennial crops",           "agriculture",
  9L,  "Silvicultura",                               "Forest plantation",               "agriculture",
  21L, "Mosaico de usos",                            "Mosaic of uses",                  "mosaic",
  24L, "Área urbanizada",                            "Urban area",                      "urban",
  75L, "Usina fotovoltaica",                         "Photovoltaic power plant",        "solar",
  23L, "Praia, duna e areal",                        "Beach, dune and sand spot",       "other",
  30L, "Mineração",                                  "Mining",                          "other",
  25L, "Outras áreas não vegetadas",                 "Other non-vegetated areas",       "other",
  33L, "Rio, lago e oceano",                         "River, lake and ocean",           "other",
  31L, "Aquicultura",                                "Aquaculture",                     "other",
  0L,  "Não observado",                              "Not observed",                    "other"
)

# MapBiomas' level-0 flag, taken from the statistics themselves.
class_map <- class_map |>
  left_join(
    coverage_raw |>
      distinct(class_id = as.integer(class), mapbiomas_level_0 = class_level_0,
               mapbiomas_level_1 = class_level_1),
    by = "class_id"
  ) |>
  left_join(select(groups, group_id, group_pt), by = "group_id") |>
  relocate(group_pt, .after = group_id)

stopifnot(
  nrow(class_map) == 30,
  setequal(class_map$class_id, unique(as.integer(coverage_raw$class))),
  !anyNA(class_map$mapbiomas_level_0)
)
write_csv(class_map, processed_path("class_groups.csv"))

native_classes  <- class_map$class_id[class_map$group_id == "native"]
natural_classes <- class_map$class_id[class_map$mapbiomas_level_0 == "Natural"]


# 3. Areas from the 30 m statistics -------------------------------------------

coverage <- coverage |>
  left_join(select(class_map, class = class_id, group_id), by = "class")

group_areas <- coverage |>
  group_by(year, group_id) |>
  summarise(area_ha = sum(area_ha), .groups = "drop") |>
  complete(year, group_id = groups$group_id, fill = list(area_ha = 0)) |>
  mutate(share = area_ha / brazil_area_ha) |>
  left_join(groups, by = "group_id") |>
  arrange(year, group_order)

stopifnot(
  group_areas |> group_by(year) |> summarise(s = sum(share)) |>
    pull(s) |> (\(s) all(abs(s - 1) < 1e-9))()
)
write_csv(group_areas, processed_path("group_areas_brazil.csv"))

biome_areas <- coverage |>
  group_by(biome, year) |>
  summarise(
    biome_ha   = sum(area_ha),
    native_ha  = sum(area_ha[class %in% native_classes]),
    natural_ha = sum(area_ha[class %in% natural_classes]),
    solar_ha   = sum(area_ha[class == 75L]),
    .groups = "drop"
  ) |>
  mutate(native_share = native_ha / biome_ha)
write_csv(biome_areas, processed_path("biome_areas.csv"))

# Headline: net loss of natural areas (MapBiomas level 0 "Natural": native
# vegetation plus natural water bodies and beaches, dunes and sand spots).
natural_by_year <- coverage |>
  filter(class %in% natural_classes) |>
  group_by(year) |>
  summarise(area_ha = sum(area_ha))
natural_loss_ha <- diff(rev(natural_by_year$area_ha))
natural_loss_share <- natural_loss_ha / brazil_area_ha

# Gross transitions 1985 -> 2024, for the validation notes.
transitions <- transition_raw |>
  transmute(biome, class_from = as.integer(class_from),
            class_to = as.integer(class_to),
            area_ha = coalesce(p1985_2024, 0))

headline <- tibble(
  natural_loss_ha    = natural_loss_ha,
  natural_loss_share = natural_loss_share,
  brazil_area_ha     = brazil_area_ha,
  solar_2024_ha      = sum(biome_areas$solar_ha[biome_areas$year == 2024]),
  solar_caatinga_share = biome_areas |>
    filter(year == 2024) |>
    summarise(s = solar_ha[biome == "Caatinga"] / sum(solar_ha)) |>
    pull(s)
)
write_csv(headline, processed_path("headline.csv"))


# 4. Validation against published figures --------------------------------------

change <- function(cls, biome_name = NULL) {
  d <- coverage
  if (!is.null(biome_name)) d <- filter(d, biome == biome_name)
  d |>
    filter(class %in% cls) |>
    group_by(year) |>
    summarise(a = sum(area_ha)) |>
    arrange(year) |>
    pull(a) |>
    diff()
}

agriculture_crops <- class_map$class_id[class_map$group_id == "agriculture" &
                                          class_map$class_id != 9L]
biome_share <- function(b, y) {
  biome_areas |> filter(biome == b, year == y) |> pull(native_share)
}
gross_native_out <- transitions |>
  filter(class_from %in% native_classes, !class_to %in% native_classes) |>
  summarise(a = sum(area_ha)) |> pull(a)

validation <- tribble(
  ~indicator,                                          ~unit,  ~reference, ~computed,
  "Perda líquida de áreas naturais (nível 0 Natural)", "Mha",  111.7,      natural_loss_ha / 1e6,
  "Perda de áreas naturais / área do país",            "%",    13,         100 * natural_loss_share,
  "Perda líquida só de vegetação nativa",              "Mha",  NA,         -change(native_classes) / 1e6,
  "Perda bruta de vegetação nativa (transições)",      "Mha",  NA,         gross_native_out / 1e6,
  "Ganho líquido de pastagem",                         "Mha",  62.7,       change(15L) / 1e6,
  "Ganho líquido de agricultura (sem silvicultura)",   "Mha",  44.0,       change(agriculture_crops) / 1e6,
  "Ganho líquido de silvicultura",                     "Mha",  NA,         change(9L) / 1e6,
  "Perda de vegetação nativa: Amazônia",               "Mha",  52.1,       -change(native_classes, "Amazônia") / 1e6,
  "Perda de vegetação nativa: Cerrado",                "Mha",  40.5,       -change(native_classes, "Cerrado") / 1e6,
  "Perda de vegetação nativa: Caatinga",               "Mha",  9.2,        -change(native_classes, "Caatinga") / 1e6,
  "Perda de vegetação nativa: Mata Atlântica",         "Mha",  4.4,        -change(native_classes, "Mata Atlântica") / 1e6,
  "Perda de vegetação nativa: Pampa",                  "Mha",  NA,         -change(native_classes, "Pampa") / 1e6,
  "Perda de vegetação nativa: Pantanal",               "Mha",  NA,         -change(native_classes, "Pantanal") / 1e6,
  "Pampa: cobertura nativa em 1985",                   "%",    64,         100 * biome_share("Pampa", 1985),
  "Pampa: cobertura nativa em 2024",                   "%",    44.5,       100 * biome_share("Pampa", 2024),
  "Usinas fotovoltaicas na Caatinga (2024)",           "%",    62,         100 * headline$solar_caatinga_share
) |>
  mutate(
    source     = "Estatísticas oficiais 30 m (bioma x UF)",
    difference = computed - reference,
    within_rounding = case_when(
      is.na(reference) ~ NA,
      # References are published with one decimal (Mha) or as rounded %.
      unit == "Mha" ~ abs(difference) < 0.05 + 1e-9,
      reference == round(reference) ~ abs(difference) < 0.5 + 1e-9,
      TRUE ~ abs(difference) < 0.05 + 1e-9
    )
  )

write_csv(validation, processed_path("validation.csv"))


# 5. Resampled maps ------------------------------------------------------------

suppressPackageStartupMessages({
  library(terra)
  library(sf)
})

# Group code used in the resampled rasters (1 to 7, in `groups` order).
group_code <- set_names(groups$group_order, groups$group_id)
reclass_table <- class_map |>
  transmute(class_id, code = group_code[group_id]) |>
  # In the 30 m rasters "not observed" is 27; 0 is the area outside Brazil.
  mutate(class_id = if_else(class_id == 0L, 27L, class_id))

# Block majority. The 30 m mosaics are in geographic coordinates (pixel of
# 0.00026949 degrees, about 30 m). A block of `fact` x `fact` source pixels
# (fact = 34 for 1 km) becomes one cell;
# the cell takes the most frequent group (ties: lowest group code, i.e. the
# order of `groups`) and records the number of photovoltaic pixels inside it.
# Reading 33 source rows at a time keeps memory below 1 GB for the whole
# country and gives exact counts, so the same pass also measures the area each
# group keeps after resampling.
resample_coverage <- function(source_file, year, fact) {
  src <- rast(source_file)
  n_groups <- nrow(groups)
  lut <- integer(256)
  lut[reclass_table$class_id + 1L] <- reclass_table$code
  out_ncol <- ceiling(ncol(src) / fact)
  out_nrow <- ceiling(nrow(src) / fact)
  majority <- matrix(NA_integer_, out_nrow, out_ncol)
  solar_px <- matrix(0L, out_nrow, out_ncol)
  group_px <- numeric(n_groups)
  block_col <- (seq_len(ncol(src)) - 1L) %/% fact
  # Area of one pixel in each row (ellipsoidal, from terra).
  one_column <- rast(nrows = nrow(src), ncols = 1, crs = crs(src),
                     extent = ext(xmin(src), xmin(src) + res(src)[1],
                                  ymin(src), ymax(src)))
  row_area_ha <- values(cellSize(one_column, unit = "ha"))[, 1]
  readStart(src)
  on.exit(readStop(src))
  for (i in seq_len(out_nrow)) {
    first_row <- (i - 1L) * fact + 1L
    n_rows <- min(fact, nrow(src) - first_row + 1L)
    v <- readValues(src, row = first_row, nrows = n_rows)
    v[is.na(v)] <- 0L
    g <- lut[v + 1L]                         # 0 = outside Brazil
    key <- rep(block_col, times = n_rows) * (n_groups + 1L) + g
    counts <- matrix(tabulate(key + 1L, nbins = out_ncol * (n_groups + 1L)),
                     nrow = n_groups + 1L)
    inside <- counts[-1, , drop = FALSE]
    has_data <- colSums(inside) > 0
    majority[i, has_data] <- max.col(t(inside[, has_data, drop = FALSE]),
                                     ties.method = "first")
    block_cols <- rep(block_col, times = n_rows)
    solar_px[i, ] <- tabulate(block_cols[v == 75L] + 1L, nbins = out_ncol)
    # Pixel area shrinks with latitude: weight each row by its own cell size.
    px_area_ha <- row_area_ha[first_row:(first_row + n_rows - 1L)]
    row_key <- rep(seq_len(n_rows) - 1L, each = ncol(src)) * (n_groups + 1L) + g
    per_row <- matrix(tabulate(row_key + 1L, nbins = n_rows * (n_groups + 1L)),
                      nrow = n_groups + 1L)
    group_px <- group_px + as.numeric(per_row[-1, , drop = FALSE] %*% px_area_ha)
    if (i %% 250 == 0) message(year, ": row ", i, " of ", out_nrow)
  }
  template <- rast(nrows = out_nrow, ncols = out_ncol, crs = crs(src),
                   extent = ext(xmin(src), xmin(src) + out_ncol * fact * res(src)[1],
                                ymax(src) - out_nrow * fact * res(src)[2], ymax(src)))
  majority_r <- setValues(template, as.vector(t(majority)))
  solar_r <- setValues(template, as.vector(t(solar_px)))
  list(
    rasters = c(majority_r, solar_r) |> setNames(c("group", "solar_px")),
    exact_ha = tibble(year = year, group_id = groups$group_id,
                      exact_area_ha = group_px)
  )
}

resampled_file <- function(year) processed_path(str_glue("map_groups_{year}.tif"))

for (year in years) {
  if (file.exists(resampled_file(year))) next
  official <- file.path(raw_dir, str_glue("brazil_coverage_{year}.tif"))
  gee_mode <- file.path(raw_dir, str_glue("col10_mode_{year}.tif"))
  gee_tiles <- list.files(file.path(raw_dir, str_glue("gee_tiles_{year}")),
                          pattern = "^tile_.*\\.tif$", full.names = TRUE)
  if (!file.exists(gee_mode) && length(gee_tiles) > 0) {
    # Tiles from gee/download_coverage_col10.py: mosaic them first.
    writeRaster(vrt(gee_tiles), gee_mode, datatype = "INT4U",
                gdal = "COMPRESS=DEFLATE", overwrite = TRUE)
  }
  if (file.exists(official)) {
    message("Resampling ", official, " (this takes a few minutes)")
    fact <- round(map_resolution_m / (res(rast(official))[2] * 110574))
    out <- resample_coverage(official, year, fact)
    writeRaster(out$rasters, resampled_file(year), datatype = "INT4U",
                gdal = "COMPRESS=DEFLATE", overwrite = TRUE)
    write_csv(out$exact_ha, processed_path(str_glue("raster_check_{year}.csv")))
  } else if (file.exists(gee_mode)) {
    # Reduced export from Earth Engine: band 1 = majority group (same codes
    # as here), band 2 = photovoltaic pixels per block.
    g <- rast(gee_mode)
    g[[1]] <- classify(g[[1]], cbind(0, NA))
    writeRaster(setNames(g, c("group", "solar_px")),
                resampled_file(year), datatype = "INT4U",
                gdal = "COMPRESS=DEFLATE", overwrite = TRUE)
  } else {
    stop(str_glue(
      "Missing map for {year}. Place `brazil_coverage_{year}.tif` (MapBiomas ",
      "Collection 10, 30 m) in {raw_dir}/. The public link is ",
      "{str_glue(coverage_url_template)} but it refuses anonymous downloads. ",
      "Alternatively run gee/download_coverage_col10.py (or the .js version)."
    ))
  }
}

maps <- set_names(years) |> map(\(y) rast(resampled_file(y)))

# Effect of resampling: share of each group in the 1 km majority map against
# the official 30 m share. Shown only in the validation table.
resampling_check <- imap(maps, \(r, y) {
  area <- cellSize(r[["group"]], unit = "ha", mask = TRUE)
  zonal(area, r[["group"]], fun = "sum", na.rm = TRUE) |>
    as_tibble() |>
    setNames(c("group_order", "map_ha")) |>
    mutate(year = as.integer(y))
}) |>
  list_rbind() |>
  left_join(group_areas, by = c("year", "group_order")) |>
  mutate(map_share = map_ha / sum(map_ha), .by = year)

solar_check <- {
  r <- maps[[as.character(years[2])]]
  # 30 m pixel area = cell area / fact^2 (fact = 34).
  px_ha <- cellSize(r[["solar_px"]], unit = "ha") / 34^2
  global(r[["solar_px"]] * px_ha, "sum", na.rm = TRUE)[[1]]
}

validation <- bind_rows(
  validation,
  resampling_check |>
    transmute(
      indicator = str_glue("Mapa 1 km (majoritária): {group_pt}, {year}"),
      unit = "%", reference = 100 * share, computed = 100 * map_share,
      source = "Comparação com a estatística oficial 30 m",
      difference = computed - reference, within_rounding = NA
    ),
  tibble(
    indicator = "Mapa: área de usinas fotovoltaicas somada nos blocos, 2024",
    unit = "ha", reference = headline$solar_2024_ha, computed = solar_check,
    source = "Comparação com a estatística oficial 30 m",
    difference = computed - reference, within_rounding = NA
  )
)
write_csv(validation, processed_path("validation.csv"))
print(validation |>
        select(indicator, unit, reference, computed, within_rounding) |>
        mutate(across(where(is.double), \(x) round(x, 2))),
      n = Inf, width = Inf)


# 6. Poster --------------------------------------------------------------------
#
# Editorial print on warm paper. Each map is the 1 km majority map shaded by
# SRTM relief and lifted off the page by a soft shadow. Leader lines point at
# real patches of each group and give its official 30 m share; the 2024 panel
# adds where native vegetation retreated, by biome.

suppressPackageStartupMessages({
  library(ggplot2)
  library(ggtext)
  library(ggfx)
  library(patchwork)
  library(systemfonts)
  library(scales)
  library(geobr)
  library(magick)
})

# 6.1 Fonts, palette, number formats

register_font(
  "Libre Baskerville",
  plain  = file.path(font_dir, "LibreBaskerville-Regular.ttf"),
  bold   = file.path(font_dir, "LibreBaskerville-Bold.ttf"),
  italic = file.path(font_dir, "LibreBaskerville-Italic.ttf")
)
register_font(
  "Lato",
  plain  = file.path(font_dir, "Lato-Regular.ttf"),
  bold   = file.path(font_dir, "Lato-Black.ttf"),
  italic = file.path(font_dir, "Lato-Italic.ttf")
)
serif <- "Libre Baskerville"
sans  <- "Lato"

# Semantic colours, checked with colorspace (deutan, protan, tritan) and
# CIEDE2000. Every pair stays apart under deutan and protan (dE >= 7.7). Under
# tritan the weakest pairs are pasture/other (5.1) and native/solar (5.5);
# solar markers also differ by shape (circles). In greyscale the three large
# groups (dark green, light ochre, mid orange) stay apart (dE >= 10); the small
# light groups rely on the direct labels.
pal <- list(
  paper  = "#F3EEE4",
  ink    = "#1E1D1B",
  muted  = "#5F5A53",
  rule   = "#C9C0B0",
  shadow = "#3B2F22"
)
group_colors <- c(
  native      = "#1E5A3C",
  pasture     = "#EBC86A",
  agriculture = "#C9551A",
  mosaic      = "#A48C8C",
  urban       = "#262626",
  solar       = "#0C6B78",
  other       = "#D2E4EE"
)

pct <- function(x, accuracy = 0.1) {
  label_number(accuracy = accuracy, decimal.mark = ",", big.mark = ".",
               suffix = "%")(100 * x)
}
num <- function(x, accuracy = 0.1) {
  label_number(accuracy = accuracy, decimal.mark = ",", big.mark = ".")(x)
}
# Letter-spaced capitals (hair spaces), for small labels.
spaced <- function(x) {
  map_chr(toupper(x), \(s) {
    words <- strsplit(s, " ")[[1]]
    letters <- map_chr(words, \(w) paste(strsplit(w, "")[[1]], collapse = "\u200a"))
    paste(letters, collapse = "\u2002")
  })
}

# 6.2 Geometry: Brazil, Caatinga, maps and relief in an equal-area projection

# Oceanic islands far off the coast (Trindade and Martim Vaz, east of 31 W)
# are dropped from the outline: at this scale they read as stray dots.
brazil_sf <- read_country(year = 2020, showProgress = FALSE) |>
  st_cast("POLYGON") |>
  (\(d) d[st_coordinates(st_centroid(st_geometry(d)))[, 1] <= -31, ])() |>
  st_transform(map_crs)
caatinga_sf <- read_biomes(year = 2019, showProgress = FALSE) |>
  filter(name_biome == "Caatinga") |>
  st_transform(map_crs)

albers_template <- rast(ext(project(maps[[1]], map_crs)), crs = map_crs,
                        resolution = map_resolution_m)
maps_albers <- map(maps, \(r) project(r[["group"]], albers_template,
                                      method = "near"))
map_ext <- unname(as.vector(ext(albers_template)))  # xmin, xmax, ymin, ymax
map_w <- diff(map_ext[1:2])
map_h <- diff(map_ext[3:4])

# Relief: SRTM elevation on the same 1 km grid (gee/download_coverage_col10.py
# --dem), exaggerated 15 times because Brazil is flat at this scale, and lit
# from three directions around the north-west so no slope goes fully black.
dem_file <- processed_path("dem_srtm_1km.tif")
if (!file.exists(dem_file)) {
  dem_tiles <- list.files(file.path(raw_dir, "gee_tiles_dem"),
                          pattern = "^tile_.*\\.tif$", full.names = TRUE)
  writeRaster(vrt(dem_tiles), dem_file, datatype = "INT2S",
              gdal = c("COMPRESS=DEFLATE", "PREDICTOR=2", "ZLEVEL=9"),
              overwrite = TRUE)
}
dem <- project(rast(dem_file), albers_template, method = "bilinear") * 15
slope <- terrain(dem, "slope", unit = "radians")
aspect <- terrain(dem, "aspect", unit = "radians")
light_angle <- 40
hillshade <- (shade(slope, aspect, light_angle, 270) +
                2 * shade(slope, aspect, light_angle, 315) +
                shade(slope, aspect, light_angle, 360)) / 4
# 1 on flat ground, below 1 on slopes facing away from the light.
relief <- as.matrix(hillshade / sin(light_angle * pi / 180), wide = TRUE)

# Colour matrix for annotation_raster (rows from north to south), with relief:
# shaded slopes darken the colour, lit slopes mix it towards white. Water is
# left flat.
relief_strength <- 0.55
color_matrix <- function(r) {
  codes <- as.matrix(r, wide = TRUE)
  codes[!codes %in% groups$group_order] <- NA   # no-data flag of INT4U
  ok <- !is.na(codes)
  base <- col2rgb(group_colors[groups$group_id])[, codes[ok]] / 255
  f <- 1 + relief_strength * (relief[ok] - 1)
  f[is.na(f) | codes[ok] == group_code[["other"]]] <- 1
  f <- pmin(pmax(f, 0.45), 1.35)
  shaded <- base * rep(pmin(f, 1), each = 3) +
    (1 - base) * rep(pmax(f - 1, 0), each = 3)
  out <- matrix(NA_character_, nrow(codes), ncol(codes))
  out[ok] <- rgb(shaded[1, ], shaded[2, ], shaded[3, ])
  out
}

# 6.3 Solar markers: photovoltaic area summed in 25 km blocks

solar_points <- {
  r <- maps[[as.character(years[2])]]
  px_ha <- cellSize(r[["solar_px"]], unit = "ha") / 34^2
  solar_ha <- aggregate(r[["solar_px"]] * px_ha, fact = 25, fun = "sum",
                        na.rm = TRUE)
  as.data.frame(solar_ha, xy = TRUE, na.rm = TRUE) |>
    setNames(c("lon", "lat", "solar_ha")) |>
    filter(solar_ha > 0) |>
    st_as_sf(coords = c("lon", "lat"), crs = 4326) |>
    st_transform(map_crs) |>
    mutate(x = st_coordinates(geometry)[, 1],
           y = st_coordinates(geometry)[, 2]) |>
    st_drop_geometry() |>
    arrange(solar_ha)
}

# 6.4 Labels with leader lines
#
# Each label points at a real patch of its group: the anchor is the 10 km cell
# of that group (majority of 1 km cells) closest to a chosen place. The check
# below stops the script if the anchor does not fall on the right colour.

label_spec <- tribble(
  ~year, ~group_id,     ~lon,   ~lat,  ~side,   ~label_y,
  1985,  "other",       -55.0,  -2.2,  "left",  0.83,
  1985,  "native",      -64.5,  -4.0,  "left",  0.64,
  1985,  "agriculture", -52.5, -24.8,  "left",  0.20,
  1985,  "pasture",     -50.0, -17.5,  "right", 0.50,
  1985,  "mosaic",      -43.5, -20.5,  "right", 0.32,
  1985,  "urban",       -46.63,-23.55, "right", 0.14,
  2024,  "other",       -55.0,  -2.2,  "left",  0.83,
  2024,  "native",      -64.5,  -4.0,  "left",  0.64,
  2024,  "agriculture", -55.8, -13.0,  "left",  0.42,
  2024,  "pasture",     -50.0, -17.5,  "right", 0.46,
  2024,  "mosaic",      -43.5, -20.5,  "right", 0.30,
  2024,  "urban",       -46.63,-23.55, "right", 0.14
)

coarse_maps <- map(maps_albers, \(r) aggregate(r, fact = 10, fun = "modal",
                                                na.rm = TRUE))

find_anchor <- function(year, group_id, lon, lat) {
  r <- coarse_maps[[as.character(year)]]
  code <- group_code[[group_id]]
  cells <- which(values(r)[, 1] == code)
  xy <- xyFromCell(r, cells)
  target <- st_coordinates(st_transform(st_sfc(st_point(c(lon, lat)),
                                               crs = 4326), map_crs))
  best <- which.min((xy[, 1] - target[1])^2 + (xy[, 2] - target[2])^2)
  # Inside that 10 km cell, the 1 km cell of the group closest to its centre.
  fine <- crop(maps_albers[[as.character(year)]],
               ext(xy[best, 1] + c(-1, 1) * res(r)[1] / 2,
                   xy[best, 2] + c(-1, 1) * res(r)[2] / 2))
  fxy <- xyFromCell(fine, which(values(fine)[, 1] == code))
  k <- which.min((fxy[, 1] - xy[best, 1])^2 + (fxy[, 2] - xy[best, 2])^2)
  tibble(anchor_x = fxy[k, 1], anchor_y = fxy[k, 2])
}

labels <- label_spec |>
  mutate(anchor = pmap(list(year, group_id, lon, lat), find_anchor)) |>
  unnest(anchor) |>
  left_join(group_areas |> select(year, group_id, group_pt, share),
            by = c("year", "group_id"))

# Every anchor must sit on its own group in the drawn map.
stopifnot(all(map2_lgl(
  labels$year, seq_len(nrow(labels)),
  \(y, i) extract(maps_albers[[as.character(y)]],
                  cbind(labels$anchor_x[i], labels$anchor_y[i]))[1, 1] ==
    group_code[[labels$group_id[i]]]
)))

# Change in percentage points, 1985 to 2024, shown next to the 2024 shares.
change_pp <- group_areas |>
  select(year, group_id, share) |>
  pivot_wider(names_from = year, values_from = share, names_prefix = "y") |>
  mutate(pp = 100 * (.data[[str_c("y", years[2])]] -
                       .data[[str_c("y", years[1])]]),
         text = str_c(if_else(pp >= 0, "+", "−"), num(abs(pp)), " p.p.")) |>
  (\(d) set_names(d$text, d$group_id))()

# Short label names on the poster.
short_name <- c(
  native = "Vegetação nativa", pasture = "Pastagem",
  agriculture = "Agricultura e silvicultura", mosaic = "Mosaico de usos",
  urban = "Área urbana", solar = "Usinas fotovoltaicas",
  other = "Água, mineração e outros"
)

# 6.5 Panel furniture: layout and biome chart

x_pad <- 0.46 * map_w
panel_xlim <- c(map_ext[1] - x_pad, map_ext[2] + x_pad)
panel_ylim <- c(map_ext[3] - 0.05 * map_h, map_ext[4] + 0.05 * map_h)
label_x <- c(left = map_ext[1] - 0.09 * map_w, right = map_ext[2] + 0.09 * map_w)
y_at <- function(f) map_ext[3] + f * map_h

# Native vegetation lost per biome, 1985 to 2024 (official statistics).
biome_loss <- biome_areas |>
  select(biome, year, native_ha) |>
  pivot_wider(names_from = year, values_from = native_ha, names_prefix = "y") |>
  mutate(loss_mha = (.data[[str_c("y", years[1])]] -
                       .data[[str_c("y", years[2])]]) / 1e6) |>
  arrange(desc(loss_mha))

biome_chart <- function() {
  x0 <- panel_xlim[1]                         # biome names, left-aligned
  xb <- x0 + 0.26 * map_w                      # bars start
  bar_max <- 0.30 * map_w
  top <- y_at(0.255)
  step <- 0.036 * map_h
  rows <- biome_loss |>
    mutate(
      i = row_number(),
      y = top - 0.095 * map_h - (i - 1) * step,
      xend = xb + pmax(loss_mha, 0) / max(loss_mha) * bar_max,
      value = if_else(loss_mha >= 0, num(loss_mha),
                      str_c("+", num(-loss_mha), " (ganho)"))
    )
  list(
    annotate("text", x = x0, y = top, hjust = 0, vjust = 1,
             label = spaced("Onde a vegetação nativa recuou"),
             family = sans, fontface = "bold", size = 8.5 / .pt,
             color = pal$ink),
    annotate("text", x = x0, y = top - 0.028 * map_h, hjust = 0, vjust = 1,
             label = "perda líquida por bioma, em milhões de hectares",
             family = sans, size = 9.5 / .pt, color = pal$muted),
    geom_text(data = rows, aes(x = x0, y = y, label = biome), hjust = 0,
              family = sans, size = 10 / .pt, color = pal$ink),
    geom_segment(data = filter(rows, loss_mha > 0),
                 aes(x = xb, xend = xend, y = y, yend = y),
                 linewidth = 2.6, color = group_colors[["native"]],
                 lineend = "butt"),
    geom_text(data = rows,
              aes(x = if_else(loss_mha > 0, xend, xb), y = y, label = value),
              hjust = 0, nudge_x = 0.012 * map_w, family = serif,
              size = 10 / .pt, color = pal$ink)
  )
}

# 6.6 One panel per year

make_panel <- function(year) {
  y <- as.character(year)
  is_last <- year == years[2]
  lab <- labels |>
    filter(year == !!year) |>
    mutate(
      label_x = label_x[side],
      label_y = y_at(label_y),
      hjust = if_else(side == "left", 1, 0),
      dir = if_else(side == "left", 1, -1),
      swatch_x = label_x + dir * 0.026 * map_w,
      line_end = swatch_x + dir * 0.014 * map_w,
      elbow_x = line_end + dir * 0.045 * map_w,
      delta = if (is_last) str_glue(
        "\u2002<span style='font-family:{sans};font-size:10pt;color:{pal$muted}'>",
        "{change_pp[group_id]}</span>"
      ) else "",
      text = str_glue(
        "<span style='font-family:\"{serif}\";font-size:23pt'>{pct(share)}</span>",
        "{delta}"
      ),
      name = spaced(short_name[group_id])
    )
  # Leader lines: horizontal from the swatch, then straight to the anchor.
  leaders <- lab |>
    select(group_id, line_end, elbow_x, label_y, anchor_x, anchor_y) |>
    pmap(\(group_id, line_end, elbow_x, label_y, anchor_x, anchor_y)
         tibble(group_id, x = c(line_end, elbow_x, anchor_x),
                y = c(label_y, label_y, anchor_y))) |>
    list_rbind()


  p <- ggplot() +
    # Map lifted off the paper by a soft shadow.
    with_shadow(
      annotation_raster(color_matrix(maps_albers[[y]]),
                        xmin = map_ext[1], xmax = map_ext[2],
                        ymin = map_ext[3], ymax = map_ext[4],
                        interpolate = FALSE),
      colour = pal$shadow, x_offset = 14, y_offset = 14, sigma = 18
    ) +
    geom_sf(data = brazil_sf, fill = NA, color = pal$ink, linewidth = 0.2)

  if (is_last) {
    solar_label_y <- y_at(0.655)
    solar_target <- solar_points |>
      st_as_sf(coords = c("x", "y"), crs = map_crs, remove = FALSE) |>
      st_filter(caatinga_sf) |>
      slice_max(solar_ha, n = 1)
    solar_line <- tibble(
      x = c(label_x[["right"]] - 0.040 * map_w,
            label_x[["right"]] - 0.085 * map_w, solar_target$x),
      y = c(solar_label_y, solar_label_y, solar_target$y)
    )
    p <- p +
      geom_sf(data = caatinga_sf, fill = NA, color = "white",
              linewidth = 0.5, linetype = "22") +
      geom_point(data = solar_points, aes(x = x, y = y, size = solar_ha),
                 shape = 21, fill = group_colors[["solar"]], color = "white",
                 stroke = 0.35) +
      scale_size_area(max_size = 4.2, guide = "none") +
      geom_path(data = solar_line, aes(x, y), color = "white",
                linewidth = 1.1, alpha = 0.7) +
      geom_path(data = solar_line, aes(x, y), color = pal$ink,
                linewidth = 0.35) +
      annotate("point", x = label_x[["right"]] - 0.026 * map_w,
               y = solar_label_y, shape = 21, size = 4.4, stroke = 0.35,
               fill = group_colors[["solar"]], color = pal$ink) +
      annotate("richtext", x = label_x[["right"]],
               y = solar_label_y - 0.012 * map_h,
               label = str_glue(
                 "<span style='font-family:\"{serif}\";font-size:23pt'>",
                 "{pct(headline$solar_caatinga_share, 1)}</span>",
                 "<span style='font-family:{sans};font-size:10pt;color:{pal$muted}'>",
                 "\u2002na Caatinga</span>"
               ),
               hjust = 0, vjust = 0, fill = NA, label.color = NA,
               label.padding = unit(0, "pt"), color = pal$ink) +
      annotate("text", x = label_x[["right"]], y = solar_label_y - 0.022 * map_h,
               label = spaced(short_name[["solar"]]), hjust = 0, vjust = 1,
               family = sans, fontface = "bold", size = 8 / .pt,
               color = pal$muted) +
      annotate("text", x = label_x[["right"]], y = solar_label_y - 0.050 * map_h,
               label = str_glue(
                 "{label_number(big.mark = '.')(round(headline$solar_2024_ha, -2))}",
                 " ha, {pct(headline$solar_2024_ha / brazil_area_ha, 0.001)} do país"
               ),
               hjust = 0, vjust = 1, family = sans, size = 9.5 / .pt,
               color = pal$muted) +
      biome_chart()
  }

  p +
    # Leader lines with a light halo so they read over the dark green.
    geom_path(data = leaders, aes(x, y, group = group_id), color = "white",
              linewidth = 1.1, alpha = 0.7, lineend = "round") +
    geom_path(data = leaders, aes(x, y, group = group_id), color = pal$ink,
              linewidth = 0.35, lineend = "round") +
    geom_point(data = lab, aes(x = anchor_x, y = anchor_y), shape = 21,
               size = 2.3, stroke = 0.7, fill = "white", color = pal$ink) +
    geom_point(data = lab, aes(x = swatch_x, y = label_y, fill = group_id),
               shape = 22, size = 4.4, stroke = 0.35, color = pal$ink) +
    scale_fill_manual(values = group_colors, guide = "none") +
    geom_richtext(data = lab,
                  aes(x = label_x, y = label_y - 0.012 * map_h, label = text,
                      hjust = hjust),
                  vjust = 0, fill = NA, label.color = NA,
                  label.padding = unit(0, "pt"), color = pal$ink) +
    geom_text(data = lab,
              aes(x = label_x, y = label_y - 0.022 * map_h, label = name,
                  hjust = hjust),
              vjust = 1, family = sans, fontface = "bold", size = 8 / .pt,
              color = pal$muted) +
    # Year, top left.
    annotate("text", x = panel_xlim[1], y = panel_ylim[2],
             label = y, family = serif, fontface = "bold", size = 58 / .pt,
             hjust = 0, vjust = 1, color = pal$ink) +
    coord_sf(crs = map_crs, xlim = panel_xlim, ylim = panel_ylim,
             expand = FALSE, datum = NA, clip = "off") +
    theme_void() +
    theme(plot.background = element_rect(fill = pal$paper, color = NA),
          plot.margin = margin(6, 0, 6, 0))
}

panels <- map(years, make_panel)

# 6.7 Composition, export and paper grain

caption_text <- "**Fonte:** MapBiomas, Coleção 10 (2025)"

poster <- panels[[1]] / panels[[2]] +
  plot_annotation(
    title = "**Cobertura e uso da terra no Brasil**",
    subtitle = "Parcela do território ocupada por cada grupo de classes, 1985 e 2024",
    caption = caption_text,
    theme = theme(
      plot.background = element_rect(fill = pal$paper, color = NA),
      plot.title = element_markdown(family = serif, size = 40, color = pal$ink,
                                    lineheight = 1.05,
                                    margin = margin(4, 0, 12, 0)),
      plot.subtitle = element_text(family = sans, size = 17, color = pal$muted,
                                   margin = margin(0, 0, 18, 0)),
      plot.caption = element_textbox_simple(
        family = sans, size = 9.5, color = pal$muted, lineheight = 1.4,
        margin = margin(16, 0, 0, 0), padding = margin(10, 0, 0, 0),
        box.colour = pal$rule, linetype = 0, halign = 0
      ),
      plot.title.position = "plot",
      plot.caption.position = "plot",
      plot.margin = margin(40, 44, 30, 44)
    )
  )

ggsave(poster_file, poster, width = poster_width_cm, height = poster_height_cm,
       units = "cm", dpi = poster_dpi, device = ragg::agg_png,
       bg = pal$paper)

# Paper grain: seeded Gaussian noise blended with soft light, so the print
# keeps its flat colours but loses the digital sheen. Deterministic.
img <- image_read(poster_file)
info <- image_info(img)
set.seed(1985)
grain <- array(pmin(pmax(rnorm(info$width * info$height, 0.5, 0.06), 0), 1),
               dim = c(info$height, info$width, 1))
img <- image_composite(img, image_read(grain), operator = "SoftLight")
image_write(img, poster_file, format = "png", density = poster_dpi)
message("Poster written to ", poster_file)
