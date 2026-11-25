#!/bin/zsh
# Downloads the FullOpen source, builds it on this Mac and installs it.
#
#   curl -fsSL https://raw.githubusercontent.com/Abhishek-programs/FullOpen/main/install.sh | zsh
set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading FullOpen..."
curl -fsSL https://github.com/Abhishek-programs/FullOpen/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP" --strip-components 1
"$TMP/build.sh" </dev/null # piped into zsh, stdin is this script
