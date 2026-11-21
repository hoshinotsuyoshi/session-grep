#!/bin/sh
# Builds Spinel at the commit in .spinel-version and installs it under PREFIX (default ~/spinel-prefix).
# CI caches PREFIX keyed on .spinel-version and this script, so this runs only when either changes.
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
# Spinel's make also builds its bundled sqlite3 extension when it finds libsqlite3, and that
# extension needs a newer libsqlite3 than ubuntu-22.04 has (sqlite3_db_name, sqlite3_error_offset
# are undefined there). session-grep doesn't use sqlite3, so tell make it isn't available
make -j"$(getconf _NPROCESSORS_ONLN)" SQLITE3_AVAILABLE=no
make install PREFIX="$prefix" SQLITE3_AVAILABLE=no
"$prefix/bin/spinel" --version
