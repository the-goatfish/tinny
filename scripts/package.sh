#!/usr/bin/env bash
# Tests, builds and archives the `can` release binary for one target, as the
# build workflow's package job does. Writes target/package/tinny-TARGET.tar.gz
# and its .sha256.
#
# Usage: scripts/package.sh [TARGET]   (default: the host target)
#
# TARGET must be one the host can run: the tests and the version check run the
# binaries it builds.
#
# Environment:
#   EXPECT_VERSION  if set, fail unless `can --version` reports exactly this
#                   version (build metadata aside), i.e. unless build.rs took
#                   its release-build path
set -euo pipefail

target=${1:-$(rustc -vV | sed -n 's/^host: //p')}
target_dir=${CARGO_TARGET_DIR:-target}

cargo test --locked --target "$target" --all-targets --all-features
cargo build --locked --profile dist --target "$target" --bin can

if [ -n "${EXPECT_VERSION:-}" ]; then
    reported=$(cargo run --quiet --locked --profile dist --target "$target" --bin can -- --version)
    case "$reported" in
        "can $EXPECT_VERSION" | "can $EXPECT_VERSION+"*) ;;
        *)
            echo "package: expected can $EXPECT_VERSION, but the binary reports: $reported" >&2
            exit 1
            ;;
    esac
fi

name=tinny-$target
staging=$target_dir/package/$name
rm -rf "$staging"
mkdir -p "$staging"
cp "$target_dir/$target/dist/can" README.md LICENSE CHANGELOG.md "$staging/"
COPYFILE_DISABLE=1 tar -C "$target_dir/package" -czf "$target_dir/package/$name.tar.gz" "$name"
(cd "$target_dir/package" && shasum -a 256 "$name.tar.gz" >"$name.tar.gz.sha256")
echo "Packaged $target_dir/package/$name.tar.gz" >&2
