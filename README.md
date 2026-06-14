# Lyrion Radio Browser Plugin

Browse and play internet radio stations from the community-driven
[Radio Browser](https://www.radio-browser.info/) directory
(`api.radio-browser.info`) directly inside
[Lyrion Music Server](https://lyrion.org/) (formerly Logitech Media Server / LMS).

The plugin registers itself under the native **Radio** menu and offers Search,
Top Stations, By Tag/Genre, and By Country browsing — with bitrate, codec, and
country shown on each station line.

---

## Features

- **Search** stations by name.
- **Top Stations** — Most Voted and Most Played.
- **By Tag / Genre** — drill into the most popular tags.
- **By Country** — browse every country with stations.
- **Station metadata** — bitrate · codec · country shown inline, plus station
  favicons as artwork.
- **Community-friendly** — honours every Radio Browser API guideline (see below).

---

## Requirements

- Lyrion Music Server **8.0** or newer.
- Network access to `api.radio-browser.info`.
- `Net::DNS` is used for mirror load-balancing when available; if it is missing
  the plugin falls back automatically, so it is **not** a hard dependency.

---

## Installation

### Recommended: add the repository (one-click install + auto-updates)

Install straight from the LMS Plugins screen and get future updates automatically.

1. Open the LMS web UI and go to **Settings → Plugins**.
2. Scroll to the bottom to **Additional Repositories** and paste this URL into
   an empty field:

   ```
   https://raw.githubusercontent.com/hjelev/lyr-radio-browser/refs/heads/master/repo.xml
   ```

3. Click **Apply**. LMS reloads the plugin list.
4. Find **Radio Browser** in the plugin list, tick its checkbox, and click
   **Apply** again.
5. **Restart Lyrion Music Server** when prompted.
6. Open the web UI → **Radio**. You should see **Radio Browser** listed.

> When a new version is published, LMS shows an update next to the plugin —
> no manual download needed.

### Alternative: manual install

1. Download the latest `RadioBrowser-<version>.zip` from the
   [Releases page](https://github.com/hjelev/lyr-radio-browser/releases)
   (or zip the `RadioBrowser/` folder yourself).
2. Locate your LMS **Plugins** directory (check **Settings → Plugins** in the web
   UI for the exact path):
   - **Linux (package):** `/var/lib/squeezeboxserver/Plugins/` or
     `/usr/share/squeezeboxserver/Plugins/`
   - **macOS:** `~/Library/Application Support/Squeezebox/Plugins/`
   - **Windows:** `C:\ProgramData\Squeezebox\Plugins\`
3. Extract so the folder lands as `Plugins/RadioBrowser/` (containing
   `Plugin.pm`, `install.xml`, and `strings.txt`).
4. **Restart Lyrion Music Server.**
5. Open the web UI → **Radio**. You should see **Radio Browser** listed.

> The directory **must** be named `RadioBrowser` so it matches the Perl package
> path `Plugins::RadioBrowser::Plugin` declared in `install.xml`.

---

## Usage

Navigate to **Radio → Radio Browser** on any player or the web UI, then pick a
browsing mode:

| Menu              | What it does                                              |
|-------------------|----------------------------------------------------------|
| Search Stations   | Type a name; results ordered by votes.                   |
| Top Stations      | Most Voted / Most Played, top 100.                        |
| By Tag / Genre    | Top 200 tags, each drilling into matching stations.       |
| By Country        | All countries; drill into stations by country code.       |

Select a station to play it. Each play is routed through the Radio Browser
click-counter so the station's popularity stats stay accurate.

---

## How it respects the Radio Browser API

The plugin follows the [API usage guidelines](https://api.radio-browser.info/)
strictly:

1. **No hardcoded mirror.** At startup it performs a DNS round-robin lookup on
   `all.api.radio-browser.info`, picks a server at random, and reverse-resolves
   it to a valid hostname for TLS. If `Net::DNS` is unavailable it falls back to
   `https://all.api.radio-browser.info`.
2. **Descriptive User-Agent.** Every request sends
   `User-Agent: LyrionRadioBrowserPlugin/1.0`.
3. **UUIDs only.** Stations are identified solely by `stationuuid`.
4. **Click tracking.** Playback is resolved through `/json/url/<uuid>`, which
   registers a click and returns the real stream URL handed to the player.

Tag and country lists are cached for 24 hours to reduce load on the directory.

---

## Architecture

```
RadioBrowser/
├── install.xml   # Plugin metadata read by LMS at startup (menu=radios, icon)
├── Plugin.pm     # Core module (extends Slim::Plugin::OPMLBased)
├── strings.txt   # Localized UI label tokens
└── HTML/EN/plugins/RadioBrowser/html/images/icon.png   # Radio-menu icon
```

The plugin appears under the **Radio** menu because `Plugin.pm` calls
`initPlugin(menu => 'radios', ...)` and `install.xml` declares an `<icon>`.

`Plugin.pm` is built on `Slim::Plugin::OPMLBased`, so LMS renders the menu
hierarchy natively. All HTTP is non-blocking via
`Slim::Networking::SimpleAsyncHTTP`, and JSON is decoded with `JSON::XS` inside
`eval` blocks for robust error handling. Failed requests degrade gracefully to a
single "Unable to load" item rather than hanging the UI.

Key subroutines:

| Sub                  | Role                                                       |
|----------------------|------------------------------------------------------------|
| `initPlugin`         | Resolves the mirror and registers under the Radio menu.    |
| `_resolveBaseUrl`    | DNS round-robin with graceful fallback.                    |
| `_apiGet`            | Central async GET + safe JSON decode.                      |
| `handleFeed`         | Builds the top-level menu.                                 |
| `searchStations`     | Name search.                                               |
| `topStations`        | Top voted / clicked.                                       |
| `listTags` / `stationsByTag`        | Tag list and drill-down.                    |
| `listCountries` / `stationsByCountry` | Country list and drill-down.              |
| `_stationsToOpml`    | Converts API stations into OPML audio items.              |
| `playStation`        | Click-tracking resolve-then-play.                         |

---

## Troubleshooting

- **Plugin doesn't appear under Radio:** confirm the folder is named exactly
  `RadioBrowser` and that LMS was restarted. Check **Settings → Plugins**.
- **Menus show "Unable to load":** verify the server can reach
  `api.radio-browser.info`; enable the `plugin.radiobrowser` log category under
  **Settings → Advanced → Logging** for details.
- **A station won't play:** the directory entry may be stale or geo-blocked; try
  another station. Broken entries (`lastcheckok == 0`) are already filtered out.

---

## Releasing (maintainers)

Distribution is driven by [`repo.xml`](repo.xml) — the repository manifest LMS
reads. Releases are **fully automated** by GitHub Actions
([`.github/workflows/release.yml`](.github/workflows/release.yml)).

To publish a new version:

1. Update `CHANGELOG.md`.
2. Tag and push:

   ```bash
   git tag v1.0.1
   git push origin v1.0.1
   ```

The workflow then:

- syncs the version into `RadioBrowser/install.xml`,
- builds `RadioBrowser-<version>.zip` via [`build.sh`](build.sh),
- creates a GitHub Release tagged `v<version>` with the zip attached,
- rewrites `repo.xml` with the release URL and the zip's **SHA1**, and commits
  it back to `master`.

Because the install URL points at `repo.xml` on `master`, LMS picks up the new
version automatically once the workflow finishes. You can also trigger it
manually from the **Actions** tab (*Release plugin → Run workflow*).

> Building locally: run `./build.sh` to produce `dist/RadioBrowser-<version>.zip`
> and print its SHA1 — handy for testing, but not required for a release.

LMS verifies the downloaded zip against `<sha>`, so the checksum **must** match
the exact asset referenced by `<url>` — the pipeline guarantees this.

## License & credits

Station data is provided by the volunteer-run
[Radio Browser](https://www.radio-browser.info/) project — please consider
contributing or donating to them.

See [CHANGELOG.md](CHANGELOG.md) for release history.
