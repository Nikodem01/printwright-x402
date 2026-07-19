# Demo catalog assets

These twelve models were designed for Printwright from parametric primitives in
[`catalog.scad`](catalog.scad). No third-party meshes or renders are included. The designs are
dedicated under `CC0-1.0`; the application itself remains under its repository-level license.

`provenance.yml` records the public slug, nominal dimensions, print orientation, support status,
and honest design caveats for every asset. PNGs are OpenSCAD renders of the exact STL geometry,
not generated illustrations.

Regenerate with OpenSCAD 2021.01 or newer:

```sh
scripts/generate_seed_assets.sh
scripts/check_seed_assets.rb
```
