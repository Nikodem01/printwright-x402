#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
asset_dir="$repo_dir/db/seed_assets"
source_file="$asset_dir/catalog.scad"

if ! command -v openscad >/dev/null 2>&1; then
  echo "OpenSCAD is required (tested with 2021.01)." >&2
  exit 1
fi

models=(
  bag-hook bag-sealer beaver-with-hat business-card-holder cable-clip cable-comb
  calibration-cube corner-jig dice-d6 drawer-label-clip drill-guide furniture-foot
  gear-toy headphone-stand hex-coaster hex-organizer hinge-pin hose-adapter
  measuring-scoop mini-funnel pen-tray phone-stand picture-stand plant-saucer
  plant-trellis planter-mini puzzle-tile soap-dish spacer-set spinning-top star-knob
  tealight-lantern tube-squeezer vase-spiral wall-bracket whistle
  open-wheel-toy-racer
)

for model in "${models[@]}"; do
  echo "Generating $model"
  openscad -q -D "model=\"$model\"" --export-format=binstl -o "$asset_dir/$model.stl" "$source_file"
  ruby "$repo_dir/scripts/canonicalize_stl.rb" "$asset_dir/$model.stl"
  QT_QPA_PLATFORM=offscreen openscad -q -D "model=\"$model\"" \
    --imgsize=800,600 --autocenter --viewall --render --colorscheme=Tomorrow \
    -o "$asset_dir/$model.png" "$source_file"
done
