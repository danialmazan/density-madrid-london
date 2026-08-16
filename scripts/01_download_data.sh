#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RAW_DIR="$ROOT_DIR/data/raw"
mkdir -p "$RAW_DIR/madrid_sections" "$RAW_DIR/london_lsoa" "$RAW_DIR/london_oa_population" "$RAW_DIR/london_oa_areas"

download_if_missing() {
  local url="$1"
  local output="$2"
  if [[ ! -s "$output" ]]; then
    curl -L --fail --retry 3 --output "$output" "$url"
  fi
}

download_if_missing \
  "https://www.ine.es/prodyser/cartografia/seccionado_2024.zip" \
  "$RAW_DIR/madrid_sections_2024.zip"
download_if_missing \
  "https://servicios.ine.es/wstempus/js/es/DATOS_TABLA/69210" \
  "$RAW_DIR/madrid_population_table_69210.json"
download_if_missing \
  "https://data.london.gov.uk/download/20od9/2a5e50ac-c22e-4d68-89e2-85f1e0ff9057/LB_LSOA2021_shp.zip" \
  "$RAW_DIR/london_lsoa_2021.zip"
download_if_missing \
  "https://www.ons.gov.uk/file?uri=%2Fpeoplepopulationandcommunity%2Fpopulationandmigration%2Fpopulationestimates%2Fdatasets%2Flowersuperoutputareamidyearpopulationestimatesnationalstatistics%2Fmid2022revisednov2025tomid2024%2Fsapelsoabroadage20222024.xlsx" \
  "$RAW_DIR/ons_lsoa_population_2022_2024.xlsx"

if [[ ! -s "$RAW_DIR/madrid_sections/SECC_CE_20240101.shp" ]]; then
  unzip -oq "$RAW_DIR/madrid_sections_2024.zip" -d "$RAW_DIR/madrid_sections"
fi
if [[ -z "$(find "$RAW_DIR/london_lsoa/LB_shp" -name '*.shp' -print -quit 2>/dev/null)" ]]; then
  unzip -oq "$RAW_DIR/london_lsoa_2021.zip" -d "$RAW_DIR/london_lsoa"
fi

# Nomis caps anonymous downloads at 25,000 observations. The 2024 OA total has
# 188,880 records, so retain eight reproducible pages and filter to London later.
for offset in 0 25000 50000 75000 100000 125000 150000 175000; do
  download_if_missing \
    "https://www.nomisweb.co.uk/api/v01/dataset/NM_2014_1.data.csv?geography=TYPE150&gender=0&c_age=200&measures=20100&time=2024&select=geography_code,obs_value,record_count&recordlimit=25000&recordoffset=${offset}" \
    "$RAW_DIR/london_oa_population/page_${offset}.csv"
done

# Exact OA areas from the ONS boundary service. The bounding box deliberately
# extends just beyond Greater London; the analysis filters by London LSOA codes.
for offset in $(seq 0 2000 30000); do
  download_if_missing \
    "https://services1.arcgis.com/ESMARspQHYMw9BZ9/arcgis/rest/services/Output_Areas_2021_EW_BFE_V9/FeatureServer/0/query?where=1%3D1&geometry=503000%2C155000%2C562000%2C201000&geometryType=esriGeometryEnvelope&spatialRel=esriSpatialRelIntersects&inSR=27700&outFields=OA21CD%2CLSOA21CD%2CShape__Area&returnGeometry=false&resultOffset=${offset}&resultRecordCount=2000&orderByFields=OA21CD&f=json" \
    "$RAW_DIR/london_oa_areas/page_${offset}.json"
done

