package Plugins::RadioBrowser::Settings;

# ----------------------------------------------------------------------------
# Web settings page for the Radio Browser plugin.
#
# Exposes a single preference - countryOverride - so the user can pin the
# country used for the "Local Stations" menu instead of relying on automatic
# geo-IP detection (handy when the server is behind a VPN). A blank value means
# auto-detect.
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
	return ( $prefs, qw(countryOverride) );
}

1;
