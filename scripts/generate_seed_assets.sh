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
  bag-hook beaver-with-hat cable-clip calibration-cube dice-d6 gear-toy
  hex-organizer phone-stand planter-mini vase-spiral wall-bracket whistle
)

for model in "${models[@]}"; do
  echo "Generating $model"
  openscad -q -D "model=\"$model\"" --export-format=binstl -o "$asset_dir/$model.stl" "$source_file"
  ruby "$repo_dir/scripts/canonicalize_stl.rb" "$asset_dir/$model.stl"
  QT_QPA_PLATFORM=offscreen openscad -q -D "model=\"$model\"" \
    --imgsize=800,600 --autocenter --viewall --render --colorscheme=Tomorrow \
    -o "$asset_dir/$model.png" "$source_file"
done
