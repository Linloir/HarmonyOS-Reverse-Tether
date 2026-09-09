#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
host_target="$(rustc -vV | awk '$1 == "host:" {print $2}')"
target="${1:-$host_target}"
if [[ "$target" == aarch64-unknown-linux-gnu && "$target" != "$host_target" ]]; then
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER:-aarch64-linux-gnu-gcc}"
fi
# Keep local source and dependency paths out of distributed executables.
# Preserve caller flags and use Cargo's encoding for paths containing spaces.
if [[ ! -v CARGO_ENCODED_RUSTFLAGS ]]; then
  relay_rustflags="${RUSTFLAGS:-}"
  read -r -a relay_flags <<< "${relay_rustflags//$'\n'/ }"
  CARGO_ENCODED_RUSTFLAGS=""
  for flag in "${relay_flags[@]}"; do
    CARGO_ENCODED_RUSTFLAGS+="${CARGO_ENCODED_RUSTFLAGS:+$'\x1f'}$flag"
  done
fi
for mapping in "$repo_dir=/src/harmony-reverse-tether" "${CARGO_HOME:-$HOME/.cargo}=/cargo"; do
  CARGO_ENCODED_RUSTFLAGS+="${CARGO_ENCODED_RUSTFLAGS:+$'\x1f'}--remap-path-prefix=$mapping"
done
export CARGO_ENCODED_RUSTFLAGS
cargo build --locked --release --manifest-path "$repo_dir/relay/Cargo.toml" --target "$target"
mkdir -p "$repo_dir/build/$target"
cp "$repo_dir/relay/target/$target/release/harmony-relay" "$repo_dir/build/$target/"
if [[ "$target" == "$host_target" ]]; then
  cp "$repo_dir/relay/target/$target/release/harmony-relay" "$repo_dir/build/harmony-relay"
fi
sha256sum "$repo_dir/build/$target/harmony-relay"
