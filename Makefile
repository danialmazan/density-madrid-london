.PHONY: data analyse validate serve

data:
	bash scripts/01_download_data.sh

analyse:
	Rscript scripts/02_analyse.R

validate:
	Rscript scripts/03_validate.R

serve:
	python3 -m http.server 8765 --bind 127.0.0.1 --directory site

