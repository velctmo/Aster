# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
