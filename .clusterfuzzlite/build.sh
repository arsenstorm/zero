#!/bin/bash -eu
# zerod's cargo-fuzz targets (crates/zerod/fuzz), with overflow checks on, each with its seed corpus.
cd "$SRC/zero/crates/zerod/fuzz"
cargo fuzz build -O --debug-assertions
./seeds.sh "$WORK/seeds"
for target in $(cargo fuzz list); do
  cp "target/x86_64-unknown-linux-gnu/release/$target" "$OUT/"
  (cd "$WORK/seeds/$target" && zip -q "$OUT/${target}_seed_corpus.zip" ./*)
done
