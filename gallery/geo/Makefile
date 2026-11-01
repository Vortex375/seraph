# Regenerates the embedded geo dataset. Run manually - NEVER at build or
# run time - so builds stay reproducible and offline. The generated file
# (data/geodata.bin.gz) is committed; this target only runs when the
# dataset itself is being refreshed.
#
# Sources:
#   - GeoNames cities500, admin1CodesASCII.txt, countryInfo.txt,
#     alternateNamesV2 (English preferred names only) - CC-BY 4.0, see
#     README.md
#   - Natural Earth ne_50m_admin_0_countries (1:50m) - public domain
#
# The huge alternateNamesV2 dump is streamed through awk straight out of
# the zip so only the English preferred names (geonameid + name) ever hit
# disk.

GEONAMES_URL := https://download.geonames.org/export/dump
NE_URL := https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_0_countries.geojson

DOWNLOADS := downloads
OUT := data/geodata.bin.gz

.PHONY: generate clean

generate: $(DOWNLOADS)/cities500.txt \
          $(DOWNLOADS)/admin1CodesASCII.txt \
          $(DOWNLOADS)/countryInfo.txt \
          $(DOWNLOADS)/geonames-en.tsv \
          $(DOWNLOADS)/ne_50m_admin_0_countries.geojson
	go run ./cmd/generate \
		-cities $(DOWNLOADS)/cities500.txt \
		-admin1 $(DOWNLOADS)/admin1CodesASCII.txt \
		-countries $(DOWNLOADS)/countryInfo.txt \
		-english $(DOWNLOADS)/geonames-en.tsv \
		-natural-earth $(DOWNLOADS)/ne_50m_admin_0_countries.geojson \
		-out $(OUT)
	@echo "dataset written to $(OUT) - commit it if the budget holds"

$(DOWNLOADS)/cities500.zip:
	mkdir -p $(DOWNLOADS)
	curl -fsSL -o $@ $(GEONAMES_URL)/cities500.zip

$(DOWNLOADS)/cities500.txt: $(DOWNLOADS)/cities500.zip
	unzip -p $< > $@

$(DOWNLOADS)/admin1CodesASCII.txt:
	mkdir -p $(DOWNLOADS)
	curl -fsSL -o $@ $(GEONAMES_URL)/admin1CodesASCII.txt

$(DOWNLOADS)/countryInfo.txt:
	mkdir -p $(DOWNLOADS)
	curl -fsSL -o $@ $(GEONAMES_URL)/countryInfo.txt

$(DOWNLOADS)/alternateNamesV2.zip:
	mkdir -p $(DOWNLOADS)
	curl -fsSL -o $@ $(GEONAMES_URL)/alternateNamesV2.zip

$(DOWNLOADS)/geonames-en.tsv: $(DOWNLOADS)/alternateNamesV2.zip
	@mkdir -p $(DOWNLOADS)
	unzip -p $< | awk -F'\t' '$$3=="en" && $$5==1 {print $$2 "\t" $$4}' > $@

$(DOWNLOADS)/ne_50m_admin_0_countries.geojson:
	mkdir -p $(DOWNLOADS)
	curl -fsSL -o $@ $(NE_URL)

clean:
	rm -rf $(DOWNLOADS)
