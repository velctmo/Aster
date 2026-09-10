.PHONY: all build app pkg run stop clean test zip benchmark integration-test

SWIFT_VER ?= $(shell swiftc --version 2>&1 | grep -Eq 'Swift version [6-9]' && echo 6 || echo 5)

all: app

build:
	@mkdir -p bin build/ModuleCache
	GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o bin/aster-daemon ./cmd/aster-daemon
	GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o bin/aster-helper ./cmd/aster-helper
	swiftc -module-cache-path $(CURDIR)/build/ModuleCache -Xcc -fmodules-cache-path=$(CURDIR)/build/ModuleCache -swift-version $(SWIFT_VER) -parse-as-library -O \
	  macos-native/Sources/Aster/Models.swift \
	  macos-native/Sources/Aster/RealtimeStores.swift \
	  macos-native/Sources/Aster/WebDAVCredentialStore.swift \
	  macos-native/Sources/Aster/AsterAPI.swift \
	  macos-native/Sources/Aster/UIComponents.swift \
	  macos-native/Sources/Aster/InspectorWindow.swift \
	  macos-native/Sources/Aster/AddRuleModalView.swift \
	  macos-native/Sources/Aster/Views.swift \
	  macos-native/Sources/Aster/ViewsMain.swift \
	  macos-native/Sources/Aster/ViewsActivity.swift \
	  macos-native/Sources/Aster/ViewsOverview.swift \
	  macos-native/Sources/Aster/ViewsOutbounds.swift \
	  macos-native/Sources/Aster/ViewsProfiles.swift \
	  macos-native/Sources/Aster/ViewsScripts.swift \
	  macos-native/Sources/Aster/ViewsRules.swift \
	  macos-native/Sources/Aster/ViewsSettings.swift \
	  macos-native/Sources/Aster/PreviewFixtures.swift \
	  macos-native/Sources/Aster/AsterApp.swift \
	  -o bin/Aster
	rm -rf build/ModuleCache

app:
	@./scripts/build_aster_mac.sh

pkg:
	@./scripts/build_aster_pkg.sh

zip: app

test:
	GOOS=darwin GOARCH=arm64 go test -race ./...

# Repeatable allocation/time baselines for the first release gate:
# 500 rendered nodes and a 100-active-connection delta.
benchmark:
	GOOS=darwin GOARCH=arm64 go test -run '^$$' -bench 'Benchmark(Render500Nodes|DiffConnections100Active|UpsertSnapshot100ActiveThrottled|ActiveSnapshotDoesNotCopyLargeImportedConfig|ActiveSnapshotDoesNotCopy500Nodes)$$' -benchmem ./internal/render ./internal/app ./internal/logstore ./internal/state

# Requires a packaged app with its bundled Apple Silicon sing-box core.
# Exercises config validation at 500 nodes and 100 simultaneous proxy clients.
integration-test: app
	GOOS=darwin GOARCH=arm64 go test -count=1 ./internal/render -run 'TestBundledSingBox(Checks500Nodes|Serves100ConcurrentProxyConnections)'

run: app
	open build/Aster.app

stop:
	pkill -f "Aster.app/Contents/MacOS/Aster" 2>/dev/null || true
	pkill -f "aster-daemon" 2>/dev/null || true

clean: stop
	rm -rf bin build
