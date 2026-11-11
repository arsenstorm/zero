#!/bin/sh
# Fills Zero/Icons.xcassets (not in git), the iPhone app's icons; run it before building. Official builds get the
# licensed Nucleo imagesets from the private zero-private repo (a checkout beside this one, or ZERO_PRIVATE=path);
# without it, the closest Lucide icons (ISC): the Mac's, under the same names (apps/macos/scripts/lucide.txt). The icons
# are the only difference; Settings › About says which. Run from anywhere: sh apps/ios/icons.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
private=${ZERO_PRIVATE:-$root/../zero-private}
out="$root/apps/ios/Zero/Icons.xcassets"
rm -rf "$out" && mkdir -p "$out"
echo '{ "info" : { "author" : "xcode", "version" : 1 } }' > "$out/Contents.json"
if ls "$private"/icons/ios/*.imageset >/dev/null 2>&1; then
    set=Nucleo
    cp -R "$private"/icons/ios/*.imageset "$out/"
else
    set=Lucide
    grep -v '^#' "$root/apps/macos/scripts/lucide.txt" | while read -r label _ fills; do
        for fill in $fills; do
            name="$label-$fill"
            mkdir "$out/$name.imageset"
            cp "$root/apps/macos/Resources/lucide/$label-outline.svg" "$out/$name.imageset/$name.svg"
            cat > "$out/$name.imageset/Contents.json" <<JSON
{ "images" : [ { "filename" : "$name.svg", "idiom" : "universal" } ], "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "preserves-vector-representation" : true, "template-rendering-intent" : "template" } }
JSON
        done
    done
fi
# Which set it is, for Settings (the data asset "icons").
mkdir "$out/icons.dataset"
printf %s "$set" > "$out/icons.dataset/icons.txt"
echo '{ "data" : [ { "filename" : "icons.txt", "idiom" : "universal" } ], "info" : { "author" : "xcode", "version" : 1 } }' \
    > "$out/icons.dataset/Contents.json"
echo "Icons: $set, $(ls -d "$out"/*.imageset | wc -l | tr -d ' ') imagesets in apps/ios/Zero/Icons.xcassets"
