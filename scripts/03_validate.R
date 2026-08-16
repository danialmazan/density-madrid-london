#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(jsonlite))

root <- getwd()
required <- c(
  "site/index.html",
  "site/styles.css",
  "site/app.js",
  "site/data.js",
  "data/derived/small_area_density.csv",
  "data/derived/population_density_deciles.csv",
  "data/derived/validation.json"
)
missing <- required[!file.exists(file.path(root, required))]
if (length(missing)) stop("Missing required files: ", paste(missing, collapse = ", "))

validation <- read_json(file.path(root, "data/derived/validation.json"), simplifyVector = TRUE)
stopifnot(
  validation$status == "passed",
  validation$madrid_sections == 2450,
  validation$london_lsoas == 4994,
  validation$london_oas == 26369,
  validation$madrid_population == 3422416,
  validation$london_population == 9089736,
  abs(validation$madrid_area_km2 - 604.4653) < 0.01,
  abs(validation$london_area_km2 - 1594.7189) < 0.01
)

html <- paste(readLines(file.path(root, "site/index.html"), warn = FALSE), collapse = "\n")
stopifnot(
  grepl("INE Annual Population Census", html, fixed = TRUE),
  grepl("ONS LSOA population estimates", html, fixed = TRUE),
  grepl("Density: Madrid vs London", html, fixed = TRUE),
  grepl("prefers-reduced-motion", paste(readLines(file.path(root, "site/styles.css"), warn = FALSE), collapse = "\n"), fixed = TRUE)
)

data_text <- paste(readLines(file.path(root, "site/data.js"), warn = FALSE), collapse = "")
payload <- fromJSON(sub("^window.DENSITY_DATA = ", "", sub(";$", "", data_text)))
stopifnot(
  nrow(payload$summary) == 2,
  abs(sum(payload$distribution$area_share[payload$distribution$city == "Madrid"]) - 1) < 1e-10,
  abs(sum(payload$distribution$population_share[payload$distribution$city == "London"]) - 1) < 1e-10,
  abs(payload$deciles$population_share[payload$deciles$city == "Madrid" & payload$deciles$area_share == 0.5] - 0.003401387) < 1e-8,
  abs(payload$deciles$population_share[payload$deciles$city == "London" & payload$deciles$area_share == 0.5] - 0.155876795) < 1e-8,
  nrow(payload$population_deciles) == 20,
  all(table(payload$population_deciles$city) == 10),
  all(diff(payload$population_deciles$density[payload$population_deciles$city == "Madrid"]) >= 0),
  all(diff(payload$population_deciles$density[payload$population_deciles$city == "London"]) >= 0),
  payload$comparison$london_p99_density > 0,
  payload$comparison$london_share_above_p99 > 0.005,
  payload$comparison$london_share_above_p99 < 0.015,
  payload$comparison$madrid_share_above_london_p99 > 0,
  payload$comparison$madrid_share_above_london_p99 < 1
)

cat("Validation passed: data reconciliation, assets, article sources, and distribution totals.\n")
