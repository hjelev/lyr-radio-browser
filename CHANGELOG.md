# Changelog

All notable changes to the Lyrion Radio Browser plugin are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- README: plugin logo is now inline with the `h1` title and slightly smaller (100 px wide).

## [v0.2.5] - 2026-06-14

### Fixed
- Tags with special characters (accented letters, Spanish titles, etc.) now resolve correctly. `_uri()` now UTF-8-encodes strings before percent-encoding, producing the correct two-byte sequences the API expects (e.g. `%C3%A1` for `á` instead of the broken `%E1`).

## [v0.2.4] - 2026-06-14

### Added
- Configurable tag list limit (`maxTags` setting, default 1000, range 1–10 000) — replaces the previous hard-coded 200-tag cap; exposed on the settings page alongside the existing station-limit setting.

## [v0.2.3] - 2026-06-14

### Added
- **Tags** section: search input at the top of the tag browse list — type a genre name to filter the full ~11 000-tag index; results link directly to stations.
- **Hide Broken Stations** toggle added to the settings page.

## [v0.2.2] - 2026-06-14

### Changed
- Internal release pipeline improvements.

## [v0.2.1] - 2026-06-14

### Changed
- Internal release pipeline improvements.

## [v0.2.0] - 2026-06-14

### Changed
- Improved settings page layout and labels.

## [v0.1.9] - 2026-06-14

### Added
- Extended configuration: `maxResults` (max stations per list) and `cacheTTL` (cache lifetime in minutes) settings added to the settings page.

## [v0.1.8] - 2026-06-14

### Added
- Plugin settings page now visible in the LMS Plugins section.

## [v0.1.7] - 2026-06-14

### Changed
- Removed the previous 100-station cap; station lists are now limited only by the configurable `maxResults` setting (default 5000).

## [v0.1.6] - 2026-06-14

### Added
- **Local Stations** section: most-voted and most-played stations for the detected (or manually overridden) country, surfaced as the first menu entry.
- Station favicons displayed as artwork in supporting LMS skins.

## [v0.1.5] - 2026-06-14

### Changed
- Station rows now show bitrate · codec · country on the second metadata line and use station favicons as artwork (falls back to the plugin icon when unavailable).

## [v0.1.4] - 2026-06-14

### Fixed
- Station listing returning incorrect results.
- Release pipeline and docs page improvements.

## [v0.1.3] - 2026-06-14

### Fixed
- Streams were displayed as non-playable folders instead of directly playable audio items.

## [v0.1.2] - 2026-06-14

### Changed
- Updated plugin icon and description text.

## [v0.1.1] - 2026-06-14

### Added
- Automated build and release pipeline (CI/CD via GitHub Actions).

## [v0.1.0] - 2026-06-14

### Added
- Initial release.
- `Slim::Plugin::OPMLBased` plugin registered under the native LMS **Radio** menu.
- **Search** stations by name (ordered by votes).
- **Top Stations** menu with Most Voted and Most Played lists.
- **By Tag / Genre** browsing — popular tags with drill-down to stations.
- **By Country** browsing — all countries with drill-down by country code.
- Non-blocking HTTP via `Slim::Networking::SimpleAsyncHTTP` with a mandatory `LyrionRadioBrowserPlugin/1.0` User-Agent on every request.
- DNS round-robin mirror selection against `all.api.radio-browser.info` using `Net::DNS`, with a graceful fallback to `https://all.api.radio-browser.info` when `Net::DNS` is unavailable.
- Click-tracking playback via the `/m3u/url/<uuid>` endpoint so each play registers a click and resolves to the live stream.
- 24-hour caching of tag and country lists via `Slim::Utils::Cache`.
- Robust error handling: JSON decoded inside `eval`, async failures degrade gracefully, broken stations filtered out by default.
- `strings.txt` with English UI labels (ready for translation).
- Plugin icon shown in the Radio menu.

[Unreleased]: https://github.com/hjelev/lyr-radio-browser/compare/v0.2.5...HEAD
[v0.2.5]: https://github.com/hjelev/lyr-radio-browser/compare/v0.2.4...v0.2.5
[v0.2.4]: https://github.com/hjelev/lyr-radio-browser/compare/v0.2.3...v0.2.4
[v0.2.3]: https://github.com/hjelev/lyr-radio-browser/compare/v0.2.2...v0.2.3
[v0.2.2]: https://github.com/hjelev/lyr-radio-browser/compare/v0.2.1...v0.2.2
[v0.2.1]: https://github.com/hjelev/lyr-radio-browser/compare/v0.2.0...v0.2.1
[v0.2.0]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.9...v0.2.0
[v0.1.9]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.8...v0.1.9
[v0.1.8]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.7...v0.1.8
[v0.1.7]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.6...v0.1.7
[v0.1.6]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.5...v0.1.6
[v0.1.5]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.4...v0.1.5
[v0.1.4]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.3...v0.1.4
[v0.1.3]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.2...v0.1.3
[v0.1.2]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.1...v0.1.2
[v0.1.1]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.0...v0.1.1
[v0.1.0]: https://github.com/hjelev/lyr-radio-browser/releases/tag/v0.1.0
