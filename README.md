# Where density lives

A visual article comparing the distribution of territorial and resident-weighted population density in Madrid and Greater London.

The article includes English and Spain-Spanish versions, equal-population density deciles, a mirrored resident distribution in 5,000 people/km² bands, and a shared upper-tail comparison based on London's population-weighted 99th-percentile LSOA density.

## Reproduce the analysis

Requirements: R with `dplyr`, `ggplot2`, `jsonlite`, `readxl`, and `sf`; plus `curl` and `unzip`.

```bash
make data
make analyse
make validate
make serve
```

Then open [http://127.0.0.1:8765](http://127.0.0.1:8765).

Live article: [https://danielalmazan.com/density-madrid-london/](https://danielalmazan.com/density-madrid-london/)

Raw downloads are excluded from version control. The derived tables, validation report, generated SVGs, and article data bundle are retained so every published number can be audited.

## Sources and vintages

- Madrid population: INE Annual Population Census, 1 January 2024, census-section totals.
- Madrid boundaries: INE census cartography, 1 January 2024.
- London population: ONS mid-2024 LSOA estimates on 2021 boundaries.
- London LSOA boundaries: GLA distribution of ONS 2021 statistical boundaries.
- OA sensitivity: ONS estimates distributed through Nomis, mid-2024, with exact ONS OA boundary areas.

The article uses complete administrative polygon area. It does not claim to measure independently classified built-up or residential land.
