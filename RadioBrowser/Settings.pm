package Plugins::RadioBrowser::Settings;

# ----------------------------------------------------------------------------
# Web settings page for the Radio Browser plugin.
#
# Exposes:
#   * countryOverride - pin the country used for "Local Stations" instead of
#     relying on automatic geo-IP detection (blank = auto-detect).
#   * maxResults      - max stations fetched per query.
#   * cacheTTL        - station-result cache lifetime, in minutes.
#   * hideBroken      - hide stations failing the last reachability check (on by
#     default; uncheck to show all stations, including broken/unverified ones).
#   * recentCount     - how many stations to remember in Recently Played.
#
# The 'recent' pref (the history list itself) is plugin-managed state and is
# deliberately not exposed here.
# ----------------------------------------------------------------------------

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.radiobrowser');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RADIOBROWSER');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/RadioBrowser/settings/basic.html');
}

sub prefs {
	return ( $prefs, qw(countryOverride maxResults topResults maxTags cacheTTL hideBroken recentCount) );
}

1;
