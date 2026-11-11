#!/usr/bin/env bash
# Regenerates AppIcon.icns from AppIcon.svg (needs macOS: qlmanage, sips, iconutil).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick (magick) is required to regenerate the icon: brew install imagemagick. The committed AppIcon.icns stays usable." >&2
  exit 1
fi

# qlmanage flattens the SVG onto white, so the rounded square is masked afterwards.
render="$tmp/AppIcon.svg.png"
if ! qlmanage -t -s 1024 -o "$tmp" "$here/AppIcon.svg" >/dev/null 2>&1 || [ ! -f "$render" ]; then
  echo "Render failed: qlmanage could not render $here/AppIcon.svg" >&2
  exit 1
fi

# Same shape as the SVG rounded square: x=64 y=64 w=896 h=896 rx=200.
masked="$tmp/AppIcon-masked.png"
magick "$render" \( -size 1024x1024 xc:none -fill white -draw "roundrectangle 64,64,959,959,200,200" \) \
  -compose CopyOpacity -composite "PNG32:$masked"
render="$masked"

iconset="$tmp/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" "$render" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" "$render" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$here/AppIcon.icns"
echo "Wrote $here/AppIcon.icns"
