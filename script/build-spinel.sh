#!/bin/sh
# Builds Spinel at the commit in .spinel-version and installs it under PREFIX (default ~/spinel-prefix).
# CI caches PREFIX keyed on .spinel-version, so this runs only when the version changes.
# Needs git, make, a C compiler, curl, and a Ruby that can require "prism" (Ruby 3.3+ ships it):
# the build runs Ruby scripts that parse Ruby.
#
#   script/build-spinel.sh [PREFIX]
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
prefix=${1:-"$HOME/spinel-prefix"}
sha=$(tr -d '[:space:]' < "$root/.spinel-version")
src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT

git clone --quiet --filter=blob:none https://github.com/matz/spinel "$src"
cd "$src"
git -c advice.detachedHead=false checkout --quiet "$sha"
make deps
make -j"$(getconf _NPROCESSORS_ONLN)"
make install PREFIX="$prefix"
"$prefix/bin/spinel" --version
