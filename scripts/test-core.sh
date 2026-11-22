#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 5 -O Sources/DateRules.swift Tests/DateRulesTests.swift -o build/test-daterules
./build/test-daterules
swiftc -swift-version 5 -O Sources/DateRules.swift Sources/FolderPattern.swift Tests/FolderPatternTests.swift -o build/test-folder-patterns
./build/test-folder-patterns
swiftc -swift-version 5 -O Sources/DateRules.swift Sources/MetadataReader.swift Sources/SidecarMatcher.swift Tests/MetadataReaderTests.swift -o build/test-metadata
./build/test-metadata
swiftc -swift-version 5 -Onone Sources/DateRules.swift Sources/MetadataReader.swift Sources/SidecarMatcher.swift \
    Sources/PersistentExifSession.swift Tests/PersistentExifTests.swift -o build/test-persistent
./build/test-persistent

if [ "$(uname -s)" = "Darwin" ]; then
    # macOS links real CryptoKit. Copies are really hashed and compared.
    swiftc -swift-version 5 -O Sources/DateRules.swift Sources/MetadataReader.swift Sources/SidecarMatcher.swift Sources/FolderPattern.swift Sources/WorkEngine.swift \
        Tests/WorkEngineTests.swift -framework CryptoKit -o build/test-operations
    ./build/test-operations
    swiftc -swift-version 5 -Onone Sources/DateRules.swift Sources/MetadataReader.swift Sources/SidecarMatcher.swift Sources/FolderPattern.swift Sources/WorkEngine.swift Sources/HistoryStore.swift Tests/HistoryStoreTests.swift \
        -framework CryptoKit -lsqlite3 -o build/test-history
    ./build/test-history
else
    # Only a build-time Linux bridge; production/macOS never contains this SHA stub.
    swiftc -swift-version 5 -emit-library -emit-module -module-name CryptoKit \
        Tests/CryptoKitLinuxStub.swift -emit-module-path build/CryptoKit.swiftmodule -o build/libCryptoKit.so
    swiftc -swift-version 5 -O -I build -L build -lCryptoKit \
        Sources/DateRules.swift Sources/MetadataReader.swift Sources/SidecarMatcher.swift Sources/FolderPattern.swift Sources/WorkEngine.swift \
        Tests/WorkEngineTests.swift -o build/test-operations
    LD_LIBRARY_PATH="$PWD/build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ./build/test-operations
    swiftc -swift-version 5 -Onone -I build -I Tests/sqlite-module -L build -lCryptoKit -lsqlite3 \
        Sources/DateRules.swift Sources/MetadataReader.swift Sources/SidecarMatcher.swift Sources/FolderPattern.swift Sources/WorkEngine.swift Sources/HistoryStore.swift \
        Tests/HistoryStoreTests.swift -o build/test-history
    LD_LIBRARY_PATH="$PWD/build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ./build/test-history
fi
