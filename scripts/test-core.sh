#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 5 -O Sources/DateRules.swift Tests/DateRulesTests.swift -o build/test-daterules
./build/test-daterules
swiftc -swift-version 5 -O Sources/DateRules.swift Sources/MetadataReader.swift Sources/SidecarMatcher.swift Tests/MetadataReaderTests.swift -o build/test-metadata
./build/test-metadata

if [ "$(uname -s)" = "Darwin" ]; then
    # macOS links real CryptoKit. Copies are really hashed and compared.
    swiftc -swift-version 5 -O Sources/DateRules.swift Sources/MetadataReader.swift Sources/SidecarMatcher.swift Sources/WorkEngine.swift \
        Tests/WorkEngineTests.swift -framework CryptoKit -o build/test-operations
    ./build/test-operations
else
    # Only a build-time Linux bridge; production/macOS never contains this SHA stub.
    swiftc -swift-version 5 -emit-library -emit-module -module-name CryptoKit \
        Tests/CryptoKitLinuxStub.swift -emit-module-path build/CryptoKit.swiftmodule -o build/libCryptoKit.so
    swiftc -swift-version 5 -O -I build -L build -lCryptoKit \
        Sources/DateRules.swift Sources/MetadataReader.swift Sources/SidecarMatcher.swift Sources/WorkEngine.swift \
        Tests/WorkEngineTests.swift -o build/test-operations
    LD_LIBRARY_PATH="$PWD/build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ./build/test-operations
fi
