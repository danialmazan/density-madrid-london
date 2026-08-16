#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(jsonlite)
  library(readxl)
  library(sf)
})

root <- normalizePath(file.path(dirname(commandArgs(trailingOnly = FALSE)[1]), ".."), mustWork = FALSE)
if (!dir.exists(file.path(root, "data"))) root <- getwd()
raw_dir <- file.path(root, "data", "raw")
derived_dir <- file.path(root, "data", "derived")
asset_dir <- file.path(root, "site", "assets")
dir.create(derived_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(asset_dir, recursive = TRUE, showWarnings = FALSE)

bins <- c(-Inf, 1000, 5000, 10000, 20000, 40000, Inf)
bin_labels <- c("0–1k", "1–5k", "5–10k", "10–20k", "20–40k", "40k+")
bin_colours <- c("#e8e4da", "#d2d2c6", "#adb8a6", "#7c9582", "#486f62", "#ef5b49")

stop_if <- function(condition, message) if (isTRUE(condition)) stop(message, call. = FALSE)
weighted_median <- function(value, weight) {
  ord <- order(value)
  value[ord][which(cumsum(weight[ord]) >= sum(weight) / 2)[1]]
}

weighted_quantile <- function(value, weight, probability) {
  ord <- order(value)
  value[ord][which(cumsum(weight[ord]) >= sum(weight) * probability)[1]]
}

population_density_deciles <- function(x, city) {
  units <- st_drop_geometry(x) |>
    arrange(density) |>
    select(density, population)
  total_population <- sum(units$population)
  breaks <- seq(0, total_population, length.out = 11)

  bind_rows(lapply(seq_len(10), function(decile) {
    lower <- breaks[decile]
    upper <- breaks[decile + 1]
    cumulative_end <- cumsum(units$population)
    cumulative_start <- cumulative_end - units$population
    population_in_decile <- pmax(0, pmin(cumulative_end, upper) - pmax(cumulative_start, lower))
    tibble(
      city = city,
      decile = decile,
      density = weighted.mean(units$density, population_in_decile)
    )
  }))
}

# Madrid: INE Annual Population Census, 1 January 2024.
madrid_geom <- st_read(
  file.path(raw_dir, "madrid_sections", "SECC_CE_20240101.shp"),
  quiet = TRUE,
  options = "ENCODING=UTF-8"
) |>
  filter(CUMUN == "28079") |>
  select(unit_id = CUSEC, district_code = CDIS, geometry) |>
  st_make_valid()

ine <- fromJSON(file.path(raw_dir, "madrid_population_table_69210.json"), simplifyVector = FALSE)
ine_rows <- lapply(ine, function(series) {
  name <- series$Nombre
  is_total <- startsWith(name, "Madrid sección") &&
    (grepl(". Total. Total. Todas las edades. Dato base.", name, fixed = TRUE) ||
       grepl(". Total. Todas las edades. Total. Dato base.", name, fixed = TRUE))
  if (!is_total) return(NULL)
  year_index <- which(vapply(series$Data, function(x) x$Anyo, integer(1)) == 2024L)
  if (!length(year_index)) return(NULL)
  datum <- series$Data[[year_index[1]]]
  section_suffix <- sub("^Madrid sección ([0-9]+)[.].*$", "\\1", name)
  data.frame(
    unit_id = paste0("28079", section_suffix),
    population = datum$Valor,
    suppressed = isTRUE(datum$Secreto),
    stringsAsFactors = FALSE
  )
}) |>
  bind_rows()

stop_if(any(ine_rows$suppressed), "Madrid contains suppressed population totals.")
stop_if(anyDuplicated(ine_rows$unit_id) > 0, "Madrid population IDs are duplicated.")
stop_if(nrow(madrid_geom) != 2450 || nrow(ine_rows) != 2450, "Unexpected Madrid section count.")

madrid <- madrid_geom |>
  left_join(ine_rows, by = "unit_id") |>
  mutate(
    area_km2 = as.numeric(st_area(geometry)) / 1e6,
    density = population / area_km2,
    density_bin = cut(density, bins, labels = bin_labels, right = FALSE)
  )
stop_if(anyNA(madrid$population), "Madrid geometry-to-population join is incomplete.")
stop_if(any(madrid$area_km2 <= 0), "Madrid contains a non-positive area.")
stop_if(sum(madrid$population) != 3422416, "Madrid population does not reconcile to the INE total.")

# London: ONS mid-2024 LSOA estimates on 2021 boundaries.
london_population <- read_excel(
  file.path(raw_dir, "ons_lsoa_population_2022_2024.xlsx"),
  sheet = "Mid-2024 LSOA 2021",
  skip = 3
) |>
  filter(startsWith(`LAD 2021 Code`, "E09")) |>
  transmute(
    unit_id = `LSOA 2021 Code`,
    unit_name = `LSOA 2021 Name`,
    borough = `LAD 2021 Name`,
    population = Total
  )

london_files <- list.files(
  file.path(raw_dir, "london_lsoa", "LB_shp"),
  pattern = "[.]shp$",
  full.names = TRUE
)
stop_if(length(london_files) != 33, "Expected 33 London borough boundary files.")
london_geom <- lapply(london_files, st_read, quiet = TRUE) |>
  bind_rows() |>
  transmute(unit_id = lsoa21cd, geometry) |>
  st_make_valid()

stop_if(anyDuplicated(london_geom$unit_id) > 0, "London LSOA boundary IDs are duplicated.")
stop_if(nrow(london_geom) != 4994 || nrow(london_population) != 4994, "Unexpected London LSOA count.")

london <- london_geom |>
  left_join(london_population, by = "unit_id") |>
  mutate(
    area_km2 = as.numeric(st_area(geometry)) / 1e6,
    density = population / area_km2,
    density_bin = cut(density, bins, labels = bin_labels, right = FALSE)
  )
stop_if(anyNA(london$population), "London geometry-to-population join is incomplete.")
stop_if(any(london$area_km2 <= 0), "London contains a non-positive area.")
stop_if(sum(london$population) != 9089736, "London population does not reconcile to the ONS total.")

city_summary <- function(x, city) {
  tibble(
    city = city,
    units = nrow(x),
    population = sum(x$population),
    area_km2 = sum(x$area_km2),
    citywide_density = sum(x$population) / sum(x$area_km2),
    resident_median_density = weighted_median(x$density, x$population),
    territorial_median_density = weighted_median(x$density, x$area_km2)
  )
}

summaries <- bind_rows(city_summary(madrid, "Madrid"), city_summary(london, "London"))

distribution <- function(x, city) {
  st_drop_geometry(x) |>
    group_by(density_bin, .drop = FALSE) |>
    summarise(area = sum(area_km2), population = sum(population), .groups = "drop") |>
    mutate(
      city = city,
      bin = as.character(density_bin),
      area_share = area / sum(area),
      population_share = population / sum(population)
    ) |>
    select(city, bin, area_share, population_share)
}
distributions <- bind_rows(distribution(madrid, "Madrid"), distribution(london, "London"))

concentration <- function(x, city) {
  out <- st_drop_geometry(x) |>
    arrange(density) |>
    transmute(
      city = city,
      area_share = cumsum(area_km2) / sum(area_km2),
      population_share = cumsum(population) / sum(population)
    )
  bind_rows(tibble(city = city, area_share = 0, population_share = 0), out)
}
concentrations <- bind_rows(concentration(madrid, "Madrid"), concentration(london, "London"))

population_at_area_share <- function(curve, share) {
  approx(curve$area_share, curve$population_share, xout = share, ties = "ordered")$y
}
decile_points <- bind_rows(lapply(c("Madrid", "London"), function(city) {
  curve <- filter(concentrations, .data$city == .env$city)
  tibble(
    city = city,
    area_share = seq(0.1, 0.9, by = 0.1),
    population_share = vapply(seq(0.1, 0.9, by = 0.1), function(x) population_at_area_share(curve, x), numeric(1))
  )
}))

population_deciles <- bind_rows(
  population_density_deciles(madrid, "Madrid"),
  population_density_deciles(london, "London")
)

madrid_top <- madrid |> slice_max(density, n = 1, with_ties = FALSE)
london_top <- london |> slice_max(density, n = 1, with_ties = FALSE)
london_max <- london_top$density[[1]]
madrid_above_london <- sum(madrid$population[madrid$density > london_max]) / sum(madrid$population)
london_p99_density <- weighted_quantile(london$density, london$population, 0.99)
london_above_p99 <- sum(london$population[london$density > london_p99_density]) / sum(london$population)
madrid_above_london_p99 <- sum(madrid$population[madrid$density > london_p99_density]) / sum(madrid$population)

district_names <- c(
  "01" = "Centro", "02" = "Arganzuela", "03" = "Retiro", "04" = "Salamanca",
  "05" = "Chamartín", "06" = "Tetuán", "07" = "Chamberí", "08" = "Fuencarral-El Pardo",
  "09" = "Moncloa-Aravaca", "10" = "Latina", "11" = "Carabanchel", "12" = "Usera",
  "13" = "Puente de Vallecas", "14" = "Moratalaz", "15" = "Ciudad Lineal", "16" = "Hortaleza",
  "17" = "Villaverde", "18" = "Villa de Vallecas", "19" = "Vicálvaro", "20" = "San Blas-Canillejas",
  "21" = "Barajas"
)

# OA sensitivity: ONS/Nomis population and exact ONS boundary areas.
oa_area_files <- list.files(file.path(raw_dir, "london_oa_areas"), pattern = "[.]json$", full.names = TRUE)
oa_areas <- lapply(oa_area_files, function(path) {
  x <- fromJSON(path)
  if (is.null(x$features) || !nrow(x$features)) return(NULL)
  x$features$attributes |>
    transmute(
      unit_id = OA21CD,
      lsoa_id = LSOA21CD,
      area_km2 = Shape__Area / 1e6
    )
}) |>
  bind_rows() |>
  distinct(unit_id, .keep_all = TRUE) |>
  filter(lsoa_id %in% london$unit_id)

oa_population_files <- list.files(file.path(raw_dir, "london_oa_population"), pattern = "[.]csv$", full.names = TRUE)
oa_population <- lapply(oa_population_files, read.csv, stringsAsFactors = FALSE) |>
  bind_rows() |>
  transmute(unit_id = GEOGRAPHY_CODE, population = OBS_VALUE) |>
  filter(unit_id %in% oa_areas$unit_id)

london_oa <- oa_areas |>
  left_join(oa_population, by = "unit_id") |>
  mutate(density = population / area_km2)
stop_if(nrow(london_oa) < 25000, "London OA sensitivity data are incomplete.")
stop_if(anyNA(london_oa$population), "London OA area-to-population join is incomplete.")
stop_if(sum(london_oa$population) != sum(london$population), "London OA totals do not reconcile to LSOA totals.")
london_oa_top <- london_oa |> slice_max(density, n = 1, with_ties = FALSE)
madrid_above_london_oa <- sum(madrid$population[madrid$density > london_oa_top$density]) / sum(madrid$population)

extremes <- tibble(
  city = c("Madrid", "London"),
  unit_id = c(madrid_top$unit_id, london_top$unit_id),
  unit_name = c(
    paste0(district_names[madrid_top$district_code], " · section ", substr(madrid_top$unit_id, 8, 10)),
    london_top$unit_name
  ),
  population = c(madrid_top$population, london_top$population),
  area_km2 = c(madrid_top$area_km2, london_top$area_km2),
  density = c(madrid_top$density, london_top$density)
)

write.csv(
  bind_rows(
    st_drop_geometry(madrid) |> transmute(city = "Madrid", unit_id, population, area_km2, density, density_bin),
    st_drop_geometry(london) |> transmute(city = "London", unit_id, population, area_km2, density, density_bin)
  ),
  file.path(derived_dir, "small_area_density.csv"),
  row.names = FALSE
)
write.csv(summaries, file.path(derived_dir, "city_summary.csv"), row.names = FALSE)
write.csv(distributions, file.path(derived_dir, "density_distribution.csv"), row.names = FALSE)
write.csv(concentrations, file.path(derived_dir, "concentration_curve.csv"), row.names = FALSE)
write.csv(population_deciles, file.path(derived_dir, "population_density_deciles.csv"), row.names = FALSE)

payload <- list(
  generated = format(Sys.Date(), "%Y-%m-%d"),
  bins = lapply(seq_along(bin_labels), function(i) list(label = bin_labels[i], colour = bin_colours[i])),
  summary = summaries,
  distribution = distributions,
  concentration = concentrations |>
    group_by(city) |>
    slice(unique(round(seq(1, n(), length.out = min(n(), 500))))) |>
    ungroup(),
  deciles = decile_points,
  population_deciles = population_deciles,
  extremes = extremes,
  comparison = list(
    london_lsoa_max = london_max,
    madrid_share_above_london_lsoa = madrid_above_london,
    london_p99_density = london_p99_density,
    london_share_above_p99 = london_above_p99,
    madrid_share_above_london_p99 = madrid_above_london_p99,
    london_oa_max = london_oa_top$density[[1]],
    london_oa_max_id = london_oa_top$unit_id[[1]],
    madrid_share_above_london_oa = madrid_above_london_oa
  )
)
writeLines(
  paste0("window.DENSITY_DATA = ", toJSON(payload, dataframe = "rows", auto_unbox = TRUE, digits = 10, na = "null"), ";"),
  file.path(root, "site", "data.js")
)

validation <- list(
  madrid_sections = nrow(madrid),
  london_lsoas = nrow(london),
  london_oas = nrow(london_oa),
  madrid_population = sum(madrid$population),
  london_population = sum(london$population),
  madrid_area_km2 = sum(madrid$area_km2),
  london_area_km2 = sum(london$area_km2),
  distribution_sums = distributions |>
    group_by(city) |>
    summarise(area = sum(area_share), population = sum(population_share), .groups = "drop"),
  status = "passed"
)
write_json(validation, file.path(derived_dir, "validation.json"), pretty = TRUE, auto_unbox = TRUE)

cat("Analysis complete\n")
print(summaries)
print(extremes)
cat(sprintf("Madrid population above London LSOA maximum: %.2f%%\n", 100 * madrid_above_london))
cat(sprintf("London resident P99 density threshold: %.0f people/km2\n", london_p99_density))
cat(sprintf("Madrid population above London P99 threshold: %.2f%%\n", 100 * madrid_above_london_p99))
cat(sprintf("Madrid population above London OA maximum: %.2f%%\n", 100 * madrid_above_london_oa))
