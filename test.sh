#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc Sources/Models.swift Sources/PresetStore.swift Sources/NetbirdClient.swift \
    Sources/RoutingController.swift Sources/MenuViews.swift Tests/main.swift -o build/NetbirdRoutingTests
build/NetbirdRoutingTests
