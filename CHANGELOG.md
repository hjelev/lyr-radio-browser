# Changelog

All notable changes to the Lyrion Radio Browser plugin are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-14

### Added
- Initial release.
- `Slim::Plugin::OPMLBased` plugin registered under the native LMS **Radio** menu.
- **Search** stations by name (ordered by votes).
- **Top Stations** menu with Most Voted and Most Played lists (top 100).
- **By Tag / Genre** browsing — top 200 tags with drill-down to stations.
- **By Country** browsing — all countries with drill-down by country code.
- Inline station metadata: bitrate · codec · country, with favicons as artwork.
- Non-blocking HTTP via `Slim::Networking::SimpleAsyncHTTP` with a mandatory
  `LyrionRadioBrowserPlugin/1.0` User-Agent on every request.
- DNS round-robin mirror selection against `all.api.radio-browser.info` using
  `Net::DNS`, with a graceful fallback to `https://all.api.radio-browser.info`
  when `Net::DNS` is unavailable.
- Click-tracking playback via `/json/url/<uuid>`: each play registers a click
  and resolves the real stream URL before handing it to the player.
- 24-hour caching of tag and country lists via `Slim::Utils::Cache`.
- Robust error handling: JSON decoded inside `eval`, async failures degrade to a
  graceful "Unable to load" item, and broken stations (`lastcheckok == 0`) are
  filtered out.
- `strings.txt` with English UI labels (ready for translation).
- HTML documentation under `docs/`.

[1.0.0]: https://github.com/jeleff/lyr-radio-browser/releases/tag/v1.0.0
