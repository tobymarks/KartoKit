#!/bin/bash
# Regionales Kachelarchiv (Protomaps-Schema, z0–15) für die Referenzfahrt Stuttgart→Pforzheim
# aus dem täglichen Protomaps-Planet-Build ausschneiden. Ergebnis: Demo/karte.pmtiles (nicht im Git).
# Voraussetzung: `brew install pmtiles`.
# Hinweis: Die Protomaps-Builds sind für Tests/Extrakte gedacht, nicht als Produktions-Tile-Server –
# produktiv gehört ein eigenes Archiv (Planetiler) auf R2/S3.
set -euo pipefail
cd "$(dirname "$0")"
DATUM="${1:-$(date -v-1d +%Y%m%d 2>/dev/null || date -d yesterday +%Y%m%d)}"
BBOX="${2:-8.55,48.70,9.30,48.98}"   # lon_min,lat_min,lon_max,lat_max
pmtiles extract "https://build.protomaps.com/${DATUM}.pmtiles" karte.pmtiles --bbox="$BBOX" --maxzoom=15
ls -la karte.pmtiles
