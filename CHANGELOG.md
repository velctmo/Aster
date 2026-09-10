# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-09-11

### Changed

- Control plane is Unix-socket only (`daemon.sock`, mode `0600`). REST and WebSocket no longer use TCP `:1780` or `ASTER_API_BASE`.
- Mixed inbound defaults to **6780** and is the only user-visible/editable port. Clash API stays internal on `127.0.0.1:9090`.
- System Proxy and TUN are independent (both may be on). Fresh installs leave capture off; the daemon enables system proxy only after the core is healthy, and restores it on stop/quit/crash.
- Settings (LAN, strict route, autostart, delay probes) are owned by the daemon. Safer defaults: strict route, LAN sharing, autostart, and passive sampling off.
- TUN uses the `mixed` stack and MTU 1500. Switching nodes or mode no longer tears down existing connections.
- Native UI waits for the socket and API token before calling the daemon, reloads the token on 401, and refreshes it before WebSocket reconnect. Tray System Proxy / TUN checkmarks follow OS state and helper capability.

### Removed

- TCP control port, `ControlPort` / `AutoConnect` settings, Clash API port editor, and GitHub sing-box download/import.
- Unused HTTP endpoints: `POST /power`, `PUT /settings`, `GET /logs`, `GET /lan`, `GET /proxy-env`, `/api/v1/core*`, `POST /open-data-dir`, `POST /window/open`.
- Passive latency sampling and persistence of the `wanted` power flag (the daemon still starts a core session while it is alive).

### Fixed

- System-proxy leftovers from a previous crash are cleared on startup using an ownership marker.
- If the helper socket exists but the helper is not running, system-proxy changes fall back to `networksetup`.
- TUN is offered only when the PKG helper is installed; the settings copy no longer implies an in-app privilege grant.

## [1.0.0] - 2026-09-10

### Added

- **Surge-Style Activity Bento Dashboard**:
  - Top network topology bar: Ethernet/Wi-Fi status, profile switcher, outbound mode selector (Rule / Global / Direct), and dual egress IP comparison (Local IP vs Proxy Egress IP with geolocation details).
  - 3-tier network latency diagnostics: Gateway ICMP/TCP ping, local recursive DNS latency, and proxy node round-trip time.
  - Real-time smooth oscilloscope for upload/download throughput with dynamic scales.
  - 24-hour traffic timeline bar chart drill-down (by App/Process, Hostname, and Policy).
  - Cycle traffic distribution (Direct vs Proxy bandwidth breakdown).

- **Surge-Style Overview Control Center**:
  - One-click toggles for System Proxy and Enhanced Mode (TUN).
  - LAN HTTP & SOCKS5 proxy sharing toggle with port configuration.
  - DHCP Gateway Mode setup guide and iCloud roaming status.

- **Status Bar Modern NSPopover Architecture**:
  - In-place interaction preserving menu state without accidental closing during delay tests.
  - Real-time top bandwidth-consuming macOS app processes with native high-res application icons.
  - Progressive streaming delay updates: nodes light up one by one via WebSocket without freezing UI.
  - Quick action shortcuts: `⌘M` (Main Window), `⌘D` (Inspector), `⌘S` (System Proxy), `⌘E` (Enhanced Mode), `⌘C` (Copy Terminal Proxy Exports), `⌘R` (Reload Config), `⌘Q` (Quit).

- **Standalone Packet Capture Inspector Window (`⌘D`)**:
  - Dedicated multi-tab analysis: Recent Requests, Active Connections, DNS, Devices, Traffic Stats, and Logbook.
  - High-density 10-column request audit table with colored method badges, matched routing rules, and destination addresses.
  - Filtering by client application or target hostname.

- **Zero-SUID Privileged Helper (`aster-helper`)**:
  - Managed by macOS `launchd` as root; strictly communicates over a Unix domain socket (`0600`).
  - Strict caller validation using `unix.GetsockoptXucred` (`LOCAL_PEERCRED`) ensuring only the installer console UID can issue commands.
  - Enforces immutable root-owned sing-box binary (`/Library/Application Support/Aster/cores/sing-box`).
  - 20-second lease expiration: automatically stops TUN core and cleans system proxies if daemon disconnects.

- **Sparkle-Inspired Network Governance**:
  - One-click rule injection directly from active connections or logs (DIRECT / PROXY / REJECT).
  - Native lightweight glass floating traffic monitor built with AppKit `NSPanel` (< 1MB RAM, ~0% idle CPU).
  - Go-native lightweight subscription cleaner: automatically strips advert nodes, ISP notifications, and regex blacklists.
  - Persistent rule & DNS override pipeline: protects custom rules from being overwritten during subscription refreshes.

- **Advanced Network Telemetry**:
  - Passive latency sampling (EMA filter): dynamically refines node latencies during daily web browsing without manual tests.
  - Multi-target ping pool (Google 204, Cloudflare, Apple Captive, custom probe URLs) with 2500ms circuit breaker.
  - Peak bandwidth test panel (⚡️ Mbps) measuring true single-stream CDN throughput.
  - iCloud Drive zero-config sync (`~/Library/Mobile Documents/com~apple~CloudDocs/Aster/`) and WebDAV backup/restore.

### Changed

- Replaced deprecated sing-box `download_detour` with sing-box 1.14+ `http_clients` and `default_http_client` architecture.
- Secured daemon HTTP & WebSocket endpoints with dynamic local Bearer token authentication to prevent DNS rebinding and cross-origin attacks.
- Main window defaults to 980x760 with AppKit `NSWindow` frame autosave persistence.

### Fixed

- Replaced failure notices with graceful placeholder badges (`---`) when switching to Direct mode or when proxy core is idle.
- Fixed carbon event tracking bug in native `NSMenu` by re-architecting status bar popup to `NSPopover`.
- Fixed test suite compatibility check when host environment has sing-box < 1.14.0.
