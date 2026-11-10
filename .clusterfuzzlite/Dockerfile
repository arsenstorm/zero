# OSS-Fuzz's Rust builder (nightly and cargo-fuzz), as of 2026-11-10.
FROM gcr.io/oss-fuzz-base/base-builder-rust@sha256:3428d0a90b1e7efbe2ba947bd1d0c9a70594986b4b6553804547f1fb24cfc92f
# The image's own nightly is older than what zerod is written in (`if let` guards); a dated one keeps the build pinned.
ENV RUSTUP_TOOLCHAIN=nightly-2026-11-01
RUN rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal
COPY . $SRC/zero
WORKDIR $SRC/zero
COPY .clusterfuzzlite/build.sh $SRC/
