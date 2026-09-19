.PHONY: all build app pkg run stop clean test zip benchmark integration-test

all: app

build:
	@mkdir -p bin
	GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o bin/aster-daemon ./cmd/aster-daemon
	GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o bin/aster-helper ./cmd/aster-helper
	@xcodebuild -project macos-native/Aster.xcodeproj -scheme Aster -configuration Release \
	  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build

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
