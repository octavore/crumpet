#!/usr/bin/env bash
# Downloads the bundled Tinted Theming scheme files into
# Sources/Crumpet/Resources/Schemes. Each entry is <system>/<slug>; the file is
# saved as <slug>.yaml, which is the name EditorColorPreset.fileName refers to.
#
# Usage: axo presets:update
#        SCHEMES_REF=<branch-or-tag> scripts/update_schemes.sh
set -euo pipefail

ref="${SCHEMES_REF:-HEAD}"
base="https://raw.githubusercontent.com/tinted-theming/schemes/$ref"
dest="$(cd "$(dirname "$0")/.." && pwd)/Sources/Crumpet/Resources/Schemes"

schemes=(
  base16/default-dark
  base16/default-light
  # The base24 Solarized files are terminal palettes with an unreadable base05
  # on the light background.
  base16/solarized-dark
  base16/solarized-light
  tinted8/gruvbox-dark
  base24/gruvbox-light
  base24/dracula
  tinted8/nord
  base16/nord-light
)

mkdir -p "$dest"
for scheme in "${schemes[@]}"; do
  curl -fsSL "$base/$scheme.yaml" -o "$dest/$(basename "$scheme").yaml"
  echo "$scheme"
done
curl -fsSL "$base/LICENSE" -o "$dest/LICENSE"
