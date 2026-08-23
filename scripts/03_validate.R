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
  "data/derived/population_density_buckets.csv",
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

buckets <- read.csv(
  file.path(root, "data/derived/population_density_buckets.csv"),
  stringsAsFactors = FALSE
)
buckets <- buckets[order(buckets$city, buckets$lower), ]
payload_buckets <- payload$population_distribution_5k
payload_buckets <- payload_buckets[order(payload_buckets$city, payload_buckets$lower), ]

stopifnot(
  nrow(buckets) == 32,
  all(table(buckets$city) == 16),
  all(buckets$population >= 0),
  identical(buckets$city, payload_buckets$city),
  all(buckets$lower == payload_buckets$lower),
  all(
    (is.infinite(buckets$upper) & is.na(payload_buckets$upper)) |
      (!is.infinite(buckets$upper) & buckets$upper == payload_buckets$upper)
  ),
  identical(buckets$label, payload_buckets$label),
  identical(buckets$population, payload_buckets$population),
  max(abs(buckets$population_share - payload_buckets$population_share)) < 1e-10
)

for (city in c("Madrid", "London")) {
  city_buckets <- buckets[buckets$city == city, ]
  stopifnot(
    all(city_buckets$lower == seq(0, 75000, by = 5000)),
    all(city_buckets$upper[1:15] == seq(5000, 75000, by = 5000)),
    is.infinite(city_buckets$upper[16]),
    all(city_buckets$upper[1:15] == city_buckets$lower[2:16]),
    abs(sum(city_buckets$population_share) - 1) < 1e-10
  )
}

share_for <- function(city, condition) {
  city_buckets <- buckets[buckets$city == city, ]
  sum(city_buckets$population_share[condition(city_buckets)])
}

stopifnot(
  abs(share_for("London", function(x) x$lower < 15000) - 0.7881546) < 1e-6,
  abs(share_for("Madrid", function(x) x$lower < 15000) - 0.2148178) < 1e-6,
  abs(share_for("Madrid", function(x) x$lower >= 25000) - 0.6104150) < 1e-6,
  abs(share_for("London", function(x) x$lower >= 25000) - 0.0348967) < 1e-6
)

cat("Validation passed: data reconciliation, assets, article sources, and distribution totals.\n")
