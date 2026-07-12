# Changelog

All notable changes to the Lyrion Radio Browser plugin are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Fixed the elapsed-time display getting stuck at "0:01 / 0:01" and bitrate/codec info never showing while a station played: stations were streamed through Radio Browser's `/m3u/url/<uuid>` click-tracking redirect, whose M3U always reports a bogus 1-second track duration. Stations now stream directly from their own URL (click tracking is preserved via a background `/json/url/<uuid>` call once playback starts).
- Huge station lists (tags/countries with thousands of stations) now load much faster: when the station count is known, pages are fetched concurrently (4 at a time) instead of one after another, cutting a 5 000-station fetch from ~10 round-trips to ~3.
- Failed or slow fetches no longer end in an empty list: whatever was retrieved is shown (flagged as a partial result), a failed first page is retried once, and search falls back to a smaller retry request before giving up.
- Plugin is now listed in the official Lyrion plugin library — install directly from **Settings → Plugins** with no custom repository URL. Docs updated accordingly.
- README: plugin logo is now inline with the title and slightly smaller.

## [v0.2.9] - 2026-06-15

- Recently Played now renders as large artwork tiles instead of a list: the Clear action carries an icon so grid-capable skins keep the tile layout.

## [v0.2.6] - 2026-06-15

- Added a **Recently Played** section that remembers the stations you actually play (most recent first, duplicates moved to the top) and persists across server restarts.
- Added a `recentCount` setting (default 100, range 1–1000) controlling how many stations are remembered, plus a **Clear recently played** action in the list.
- Plays are captured by observing playlist commands, leaving the proven `/m3u/url/<uuid>` playback path (and community click tracking) unchanged.

## [v0.2.5] - 2026-06-14

- Fixed tags with special characters (accented letters, Spanish titles, etc.) returning no stations — `_uri()` now produces correct UTF-8 percent-encoding.

## [v0.2.4] - 2026-06-14

- Added `maxTags` setting (default 1000, range 1–10 000) to control how many tags appear in the Tags browse list, replacing the previous hard-coded 200-tag cap.

## [v0.2.3] - 2026-06-14

- Added **Tags** section with a search input at the top to filter the full ~11 000-tag index.
- Added **Hide Broken Stations** toggle to the settings page.

## [v0.2.0] - 2026-06-14

- Improved settings page layout and labels.

## [v0.1.9] - 2026-06-14

- Added `maxResults` (max stations per list) and `cacheTTL` (cache lifetime in minutes) settings.

## [v0.1.7] - 2026-06-14

- Removed the previous 100-station cap; lists now respect the configurable `maxResults` setting.

## [v0.1.6] - 2026-06-14

- Added **Local Stations** section showing the most-voted stations for the detected (or manually set) country.
- Added station favicon support.

## [v0.1.5] - 2026-06-14

- Station rows now show bitrate · codec · country on the second line, with favicons as artwork.

## [v0.1.3] - 2026-06-14

- Fixed stations appearing as non-playable folders instead of directly playable audio items.

## [v0.1.0] - 2026-06-14

- Initial release: Search, Top Stations, By Tag/Genre, and By Country menus under the native LMS Radio menu.
- DNS round-robin mirror selection, mandatory User-Agent, click-tracking playback, and 24-hour tag/country list caching.

[Unreleased]: https://github.com/hjelev/lyr-radio-browser/compare/v0.2.5...HEAD
[v0.2.5]: https://github.com/hjelev/lyr-radio-browser/compare/v0.2.4...v0.2.5
[v0.2.4]: https://github.com/hjelev/lyr-radio-browser/compare/v0.2.3...v0.2.4
[v0.2.3]: https://github.com/hjelev/lyr-radio-browser/compare/v0.2.2...v0.2.3
[v0.2.0]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.9...v0.2.0
[v0.1.9]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.8...v0.1.9
[v0.1.7]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.6...v0.1.7
[v0.1.6]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.5...v0.1.6
[v0.1.5]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.4...v0.1.5
[v0.1.3]: https://github.com/hjelev/lyr-radio-browser/compare/v0.1.2...v0.1.3
[v0.1.0]: https://github.com/hjelev/lyr-radio-browser/releases/tag/v0.1.0
