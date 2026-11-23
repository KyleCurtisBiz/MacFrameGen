#!/bin/zsh
# Compiles every single-file experiment in this folder into Research/bin/.
set -e
cd "$(dirname "$0")"
mkdir -p bin
for f in *.swift; do
  echo "building ${f%.swift}"
  swiftc -O -swift-version 5 -suppress-warnings "$f" -o "bin/${f%.swift}"
done
