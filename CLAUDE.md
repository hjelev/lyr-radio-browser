# Project Context: Lyrion Music Server (LMS) Radio Browser Plugin

## 1. Project Overview
You are acting as an expert Perl developer specializing in Lyrion Music Server (formerly Logitech Media Server / LMS) architecture. 
Your task is to build a complete, production-ready Radio Browser plugin for Lyrion using the free, community-driven API at `api.radio-browser.info`.

## 2. Technical Stack & Environment
*   **Language:** Perl 5
*   **Target Platform:** Lyrion Music Server (LMS) version 8.0 and above.
*   **Base Class:** `Slim::Plugin::OPMLBased` (This must be used to natively handle hierarchical menus, directories, and search results in the Lyrion UI).
*   **Networking:** `Slim::Networking::SimpleAsyncHTTP` (Lyrion's built-in non-blocking HTTP module must be used for all API calls).
*   **JSON Parsing:** `JSON::XS::decode_json` (or `Slim::Utils::OSDetect::details()->{'os'} eq 'win' ? JSON::from_json : JSON::XS::decode_json` as standard LMS practice).

## 3. Strict API Requirements (Radio Browser)
When writing the plugin logic, you **must** strictly adhere to these API rules. Do not bypass them:

1.  **Dynamic DNS Resolution (Load Balancing):** 
    *   *Do not hardcode* an API server URL (e.g., `de1.api.radio-browser.info`). 
    *   On plugin initialization, use `Net::DNS` to perform a DNS A/CNAME/SRV round-robin lookup on `all.api.radio-browser.info`.
    *   Randomly select one of the returned IP addresses/hosts to use as the base URL for the current session.
2.  **Mandatory User-Agent:**
    *   Every HTTP request must include a descriptive `User-Agent` header (e.g., `LyrionRadioBrowserPlugin/1.0`). Generic or missing user agents will be blocked by the API.
3.  **UUIDs Only:**
    *   Rely entirely on the `stationuuid` field from the JSON responses. Do not use legacy integer IDs.
4.  **Click Tracking / Playback Routing:**
    *   Do not pass the raw audio stream URL to the Lyrion player. 
    *   Route playback requests through the click-tracking endpoint: `$BASE_URL/json/url/$stationuuid`. This counts as a "click" for community popularity metrics and redirects the player to the actual stream.

## 4. Required File Structure
The plugin must contain at least the following files:

*   `install.xml`: Contains plugin metadata (name, version, creator, LMS minVersion 8.0).
*   `Plugin.pm`: The core Perl module extending `Slim::Plugin::OPMLBased`.

## 5. UI & Menu Structure Requirements
The plugin should register itself under Lyrion's main **Radio** menu. 
Provide OPML menu endpoints for:
*   **Search:** Allow the user to input text to search by station name.
*   **Top Stations:** Fetch and display top voted or top clicked stations.
*   **By Tag/Genre:** Fetch a list of tags, allowing the user to drill down into stations by tag.
*   **By Country:** Fetch a list of countries, allowing the user to drill down.

## 6. Your Task
Please generate the complete source code for `install.xml` and `Plugin.pm`. 
Ensure the Perl code includes robust error handling (e.g., catching JSON parsing errors, handling async HTTP failures gracefully) and is heavily commented so a Lyrion administrator can easily install and maintain it.
