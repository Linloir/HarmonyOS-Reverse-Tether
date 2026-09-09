#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/build"
cpp_dir="$repo_dir/app/entry/src/main/cpp"
g++ -std=c++17 -Wall -Wextra -Werror -pthread -fsanitize=address,undefined -g \
  -I "$cpp_dir" "$repo_dir/tests/tunnel_test.cpp" "$cpp_dir/tunnel.cpp" -o "$repo_dir/build/tunnel-test"
"$repo_dir/build/tunnel-test"
