package Plugins::RadioBrowser::Plugin;

# ----------------------------------------------------------------------------
# Lyrion Music Server (LMS) - Radio Browser plugin
#
# Browses the community-driven directory at api.radio-browser.info and exposes
# Search / Top Stations / By Tag / By Country menus under the native LMS Radio
# menu. Built on Slim::Plugin::OPMLBased so LMS renders the hierarchy natively.
#
# API etiquette enforced (see Radio Browser docs):
#   * No hardcoded mirror - a server is chosen at init via DNS round-robin on
#     all.api.radio-browser.info (with a graceful fallback).
#   * Every request carries a descriptive User-Agent header.
#   * Stations are identified only by their stationuuid.
#   * Playback is routed through the /json/url/<uuid> click-tracking endpoint so
#     each play counts toward community popularity metrics.
# ----------------------------------------------------------------------------

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Cache;
use Slim::Utils::Prefs;

use URI::Escape qw(uri_escape_utf8);

# JSON decoder. LMS bundles JSON::XS; we keep a single entry point so all
# decoding is wrapped in eval for robust error handling.
use JSON::XS ();

use constant USER_AGENT  => 'lyr-radio-browser/0.3.0 (https://github.com/hjelev/lyr-radio-browser)';
use constant DNS_NAME    => 'all.api.radio-browser.info';
use constant FALLBACK_URL => 'https://all.api.radio-browser.info';
use constant LIST_TTL    => 86400;    # cache tags/countries for 1 day
use constant GEO_TTL     => 604800;   # cache detected country for 7 days
# Defaults for the user-configurable station result cap / cache lifetime
# (overridable via the settings page; see _maxResults / _cacheTTLSecs).
use constant DEFAULT_MAX_RESULTS   => 5000;   # effectively "all"; bounds worst-case size
use constant DEFAULT_TOP_RESULTS   => 100;    # global Most Voted/Most Played chart size
use constant DEFAULT_MAX_TAGS      => 1000;   # popular tags shown in browse list
use constant DEFAULT_CACHE_TTL_MIN => 60;     # cache station result lists for 1 hour
use constant DEFAULT_RECENT_COUNT  => 100;    # stations remembered in Recently Played
use constant META_TTL              => 2592000;# 30d: uuid->metadata cache for play-time lookup

# IP-geolocation providers, tried in order until one yields a 2-letter country
# code. LMS has no built-in country pref, so we infer it from the server's
# public IP. Each entry maps the provider's JSON fields to code/name (name is
# optional - when absent we derive a display name from the code via
# _countryName). The LMS community service is purpose-built for plugins (no rate
# limit) so it is tried first; the rate-limited third-party APIs remain as
# fallbacks should it ever be unavailable.
use constant GEO_PROVIDERS => (
	{ url => 'https://api.lms-community.org/geoip/', code => 'country' },
	{ url => 'https://ipapi.co/json/', code => 'country_code', name => 'country_name' },
	{ url => 'https://ipwho.is/',      code => 'country_code', name => 'country'      },
);

# Logger category - configurable under Settings > Advanced > Logging.
my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.radiobrowser',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_RADIOBROWSER',
});

# Plugin preferences (manual country override; blank = auto-detect).
my $prefs = preferences('plugin.radiobrowser');

my $cache;

# Base URL for this server session, chosen once at init.
my $BASE_URL = FALLBACK_URL;

# ----------------------------------------------------------------------------
# Plugin lifecycle
# ----------------------------------------------------------------------------

sub initPlugin {
	my $class = shift;

	$cache = Slim::Utils::Cache->new();

	$prefs->init({
		countryOverride => '',
		maxResults      => DEFAULT_MAX_RESULTS,
		topResults      => DEFAULT_TOP_RESULTS,
		maxTags         => DEFAULT_MAX_TAGS,
		cacheTTL        => DEFAULT_CACHE_TTL_MIN,
		hideBroken      => 1,
		recentCount     => DEFAULT_RECENT_COUNT,
		menuLocation    => 'radios',
		recent          => [],
	});

	# Keep the numeric prefs sane: positive integers within practical bounds.
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 100000 }, 'maxResults');
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 10000  }, 'topResults');
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 10000  }, 'maxTags');
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 10080  }, 'cacheTTL');
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 1000   }, 'recentCount');

	# Observe playlist commands so each play is captured for the Recently Played
	# list. This is a passive observer (it never modifies playback), and it is
	# guarded so a failure here can never abort initPlugin.
	eval {
		require Slim::Control::Request;
		Slim::Control::Request::subscribe(
			\&_onPlaylistCmd,
			[ ['playlist'], ['play', 'load', 'add', 'insert'] ],
		);
	};
	$log->error("Radio Browser: could not subscribe to playlist commands: $@") if $@;

	# Pick an API mirror via DNS round-robin. Fire-and-forget and fully
	# non-blocking: $BASE_URL stays at FALLBACK_URL (a working round-robin
	# endpoint) until the async resolution lands and updates it.
	_resolveBaseUrlAsync();

	# Web settings page for the manual country override (web UI only).
	if ( main::WEBUI ) {
		require Plugins::RadioBrowser::Settings;
		Plugins::RadioBrowser::Settings->new;
	}

	# Auto-detect the listener's country in the background (unless overridden).
	_maybeDetectCountry();

	# Menu placement (Radio vs Apps) is settings-configurable but only read once
	# here at init, so a change takes effect on the next server restart.
	my $under_apps = _menuLocation() eq 'apps';

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'radiobrowser',
		menu   => $under_apps ? 'apps' : 'radios',
		is_app => $under_apps ? 1 : 0,
		weight => 50,
	);
}

sub getDisplayName { 'PLUGIN_RADIOBROWSER' }

# ----------------------------------------------------------------------------
# DNS load balancing (CLAUDE.md sec 3.1) with graceful fallback.
#
# Asynchronously resolve A records for all.api.radio-browser.info, pick one at
# random, then reverse-resolve it to a real mirror hostname (e.g.
# de1.api.radio-browser.info) and pin $BASE_URL to it for the session.
#
# This MUST stay non-blocking: LMS runs a single-threaded event loop, so a
# synchronous DNS lookup at init could stall the whole server (and playback) for
# seconds (see issue #3). We use AnyEvent::DNS - the same async resolver LMS uses
# internally via Slim::Networking::Async::DNS - which schedules its own timeouts
# and retries on the event loop. The LMS wrapper itself is not usable here: it
# does forward A-resolution only, returns a single address, and has no PTR,
# whereas we need the full A-record list (to randomize) plus a reverse lookup.
#
# Until resolution lands $BASE_URL stays at FALLBACK_URL, which is a fully
# working round-robin endpoint (the wildcard TLS cert covers both it and the
# specific mirrors, so the PTR step is for honoring the per-mirror API guidance,
# not for cert validity). Any failure simply leaves FALLBACK_URL in place.
# ----------------------------------------------------------------------------

sub _resolveBaseUrlAsync {
	my $ok = eval {
		require AnyEvent::DNS;

		AnyEvent::DNS::a( DNS_NAME, sub {
			my @ips = @_;
			unless ( @ips ) {
				$log->warn( 'DNS round-robin: no A records for ' . DNS_NAME . "; keeping $BASE_URL" );
				return;
			}

			# Random selection spreads load across mirrors per the API guidelines.
			my $ip = $ips[ int( rand( scalar @ips ) ) ];

			# Reverse-resolve so the HTTPS Host header / TLS SNI is a real mirror name.
			AnyEvent::DNS::reverse_lookup( $ip, sub {
				my ( $host ) = @_;
				unless ( $host ) {
					$log->warn( "DNS round-robin: no PTR for $ip; keeping $BASE_URL" );
					return;
				}

				$host =~ s/\.$//;
				$BASE_URL = "https://$host";
				$log->info("Radio Browser using base URL: $BASE_URL");
			} );
		} );

		1;
	};

	if ( !$ok ) {
		$log->warn( 'DNS round-robin unavailable (' . ( $@ || 'unknown' ) . "); keeping $BASE_URL" );
	}
}

# ----------------------------------------------------------------------------
# Central async fetch helper. Performs a non-blocking GET against the chosen
# mirror, decodes JSON safely, and routes results to $cb / errors to $ecb.
# ----------------------------------------------------------------------------

sub _apiGet {
	my ( $path, $cb, $ecb ) = @_;

	my $url = $BASE_URL . $path;
	$log->debug("GET $url");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $data = eval { JSON::XS::decode_json( $http->content ) };

			if ( $@ || !defined $data ) {
				$log->error("JSON decode failed for $url: " . ( $@ || 'empty' ));
				return $ecb->("decode error");
			}

			$cb->($data);
		},
		sub {
			my ( $http, $error ) = @_;
			$log->error("HTTP request failed for $url: " . ( $error || 'unknown' ));
			$ecb->( $error || 'http error' );
		},
		{
			timeout => 15,
		},
	)->get( $url, 'User-Agent' => USER_AGENT );
}

# Build a single OPML error item so menus degrade gracefully instead of hanging.
sub _errorItems {
	return {
		items => [ { name => cstring( undef, 'PLUGIN_RADIOBROWSER_ERROR' ), type => 'text' } ],
	};
}

# ----------------------------------------------------------------------------
# Top-level menu
# ----------------------------------------------------------------------------

sub handleFeed {
	my ( $client, $cb, $args ) = @_;

	# Resolve the listener's country (manual override or auto-detected). If it
	# isn't known yet, trigger detection so a later menu open can show it.
	my ( $code, $name ) = _activeCountry();
	_maybeDetectCountry() unless $code;

	# Top Stations: the global lists, plus country-specific ones when known.
	my @top = (
		{
			name => cstring( $client, 'PLUGIN_RADIOBROWSER_TOP_VOTED' ),
			type => 'link',
			url  => \&topStations,
			passthrough => [ { order => 'topvote' } ],
		},
		{
			name => cstring( $client, 'PLUGIN_RADIOBROWSER_TOP_CLICKED' ),
			type => 'link',
			url  => \&topStations,
			passthrough => [ { order => 'topclick' } ],
		},
	);

	if ( $code ) {
		push @top,
			{
				name => cstring( $client, 'PLUGIN_RADIOBROWSER_TOP_VOTED' ) . " \x{00B7} $name",
				type => 'link',
				url  => \&stationsByCountry,
				passthrough => [ { code => $code, order => 'votes' } ],
			},
			{
				name => cstring( $client, 'PLUGIN_RADIOBROWSER_TOP_CLICKED' ) . " \x{00B7} $name",
				type => 'link',
				url  => \&stationsByCountry,
				passthrough => [ { code => $code, order => 'clickcount' } ],
			};
	}

	my @items = (
		{
			name  => cstring( $client, 'PLUGIN_RADIOBROWSER_SEARCH' ),
			type  => 'search',
			url   => \&searchStations,
		},
		{
			name  => cstring( $client, 'PLUGIN_RADIOBROWSER_TOP' ),
			type  => 'link',
			items => \@top,
		},
		{
			name  => cstring( $client, 'PLUGIN_RADIOBROWSER_BY_TAG' ),
			type  => 'link',
			url   => \&listTags,
		},
		{
			name  => cstring( $client, 'PLUGIN_RADIOBROWSER_BY_COUNTRY' ),
			type  => 'link',
			url   => \&listCountries,
		},
	);

	# Recently Played: locally remembered history, surfaced near the top.
	unshift @items, {
		name => cstring( $client, 'PLUGIN_RADIOBROWSER_RECENT' ),
		type => 'link',
		url  => \&recentStations,
	};

	# Surface local stations prominently as the very first entry.
	if ( $code ) {
		unshift @items, {
			name  => cstring( $client, 'PLUGIN_RADIOBROWSER_LOCAL' ) . " \x{00B7} $name",
			type  => 'link',
			url   => \&stationsByCountry,
			passthrough => [ { code => $code, order => 'votes' } ],
		};
	}

	$cb->({ items => \@items });
}

# ----------------------------------------------------------------------------
# Search by station name. OPML supplies the typed query in $args->{search}.
# ----------------------------------------------------------------------------

sub searchStations {
	my ( $client, $cb, $args ) = @_;

	my $query = $args->{search} || '';
	$query =~ s/^\s+|\s+$//g;

	return $cb->( { items => [ { name => cstring( $client, 'PLUGIN_RADIOBROWSER_NONE' ), type => 'text' } ] } )
		unless length $query;

	my $path = '/json/stations/byname/' . _uri( $query )
		. '?limit=' . _maxResults() . '&order=votes&reverse=true' . _brokenSuffix();

	_stationsRequest( $client, $cb, $path );
}

# ----------------------------------------------------------------------------
# Top stations (most voted or most clicked).
# ----------------------------------------------------------------------------

sub topStations {
	my ( $client, $cb, $args, $pt ) = @_;

	my $order = ( $pt && $pt->{order} ) || 'topvote';
	my $path  = "/json/stations/$order/" . _topResults();
	$path .= '?hidebroken=true' if _hideBroken();

	_stationsRequest( $client, $cb, $path );
}

# ----------------------------------------------------------------------------
# Tag / genre list -> drill into stations for the chosen tag.
# ----------------------------------------------------------------------------

sub listTags {
	my ( $client, $cb, $args ) = @_;

	my $search_item = {
		name => cstring( $client, 'PLUGIN_RADIOBROWSER_SEARCH_TAGS' ),
		type => 'search',
		url  => \&searchTags,
	};

	# Cache key encodes the limit so a settings change yields a fresh fetch.
	my $cache_key = 'radiobrowser_tags:' . _maxTags();
	my $cached    = $cache->get($cache_key);
	if ( $cached ) {
		my $items = _tagItems( $client, $cached );
		return $cb->( { items => [ $search_item, @$items ] } );
	}

	_apiGet(
		'/json/tags?order=stationcount&reverse=true&limit=' . _maxTags() . _brokenSuffix(),
		sub {
			my $tags = shift;
			$cache->set( $cache_key, $tags, LIST_TTL );
			my $items = _tagItems( $client, $tags );
			$cb->( { items => [ $search_item, @$items ] } );
		},
		sub { $cb->( _errorItems() ) },
	);
}

sub searchTags {
	my ( $client, $cb, $args ) = @_;

	my $query = $args->{search} || '';
	$query =~ s/^\s+|\s+$//g;

	return $cb->( { items => [ { name => cstring( $client, 'PLUGIN_RADIOBROWSER_NONE' ), type => 'text' } ] } )
		unless length $query;

	_apiGet(
		'/json/tags/' . _uri($query) . '?order=stationcount&reverse=true&limit=100',
		sub {
			my $tags = shift;
			$cb->( { items => _tagItems( $client, $tags ) } );
		},
		sub { $cb->( _errorItems() ) },
	);
}

sub _tagItems {
	my ( $client, $tags ) = @_;

	my @items =
		map {
			{
				name        => ucfirst( $_->{name} ) . ' (' . ( $_->{stationcount} || 0 ) . ')',
				type        => 'link',
				url         => \&stationsByTag,
				passthrough => [ { tag => $_->{name} } ],
			}
		}
		grep { $_->{name} && ( $_->{stationcount} || 0 ) > 0 }
		@{ $tags || [] };

	return @items ? \@items : [ { name => cstring( $client, 'PLUGIN_RADIOBROWSER_NONE' ), type => 'text' } ];
}

sub stationsByTag {
	my ( $client, $cb, $args, $pt ) = @_;

	my $tag  = ( $pt && $pt->{tag} ) || '';
	my $path = '/json/stations/bytagexact/' . _uri( $tag )
		. '?limit=' . _maxResults() . '&order=votes&reverse=true' . _brokenSuffix();

	_stationsRequest( $client, $cb, $path );
}

# ----------------------------------------------------------------------------
# Country list -> drill into stations for the chosen country code.
# ----------------------------------------------------------------------------

sub listCountries {
	my ( $client, $cb, $args ) = @_;

	my $cached = $cache->get('radiobrowser_countries');
	return $cb->( { items => _countryItems( $client, $cached ) } ) if $cached;

	_apiGet(
		'/json/countries?order=name' . _brokenSuffix(),
		sub {
			my $countries = shift;
			$cache->set( 'radiobrowser_countries', $countries, LIST_TTL );
			$cb->( { items => _countryItems( $client, $countries ) } );
		},
		sub { $cb->( _errorItems() ) },
	);
}

sub _countryItems {
	my ( $client, $countries ) = @_;

	my @items =
		map {
			{
				name        => $_->{name} . ' (' . ( $_->{stationcount} || 0 ) . ')',
				type        => 'link',
				url         => \&stationsByCountry,
				passthrough => [ { code => $_->{iso_3166_1} } ],
			}
		}
		grep { $_->{name} && $_->{iso_3166_1} && ( $_->{stationcount} || 0 ) > 0 }
		@{ $countries || [] };

	return @items ? \@items : [ { name => cstring( $client, 'PLUGIN_RADIOBROWSER_NONE' ), type => 'text' } ];
}

sub stationsByCountry {
	my ( $client, $cb, $args, $pt ) = @_;

	my $code  = ( $pt && $pt->{code} )  || '';
	# Order defaults to votes; callers can request 'clickcount' for "most played".
	my $order = ( $pt && $pt->{order} ) || 'votes';
	my $path = '/json/stations/bycountrycodeexact/' . _uri( $code )
		. '?limit=' . _maxResults() . '&order=' . _uri( $order ) . '&reverse=true' . _brokenSuffix();

	_stationsRequest( $client, $cb, $path );
}

# ----------------------------------------------------------------------------
# Fetch a station list (cached) and hand it back as a grid feed.
#
# The full result set is cached per query ($path uniquely encodes it) so large
# lists aren't refetched while the user scrolls/pages. We return ALL stations:
# LMS XMLBrowser windows long lists server-side, so the client only receives the
# slice it asks for and gets native scroll / next-page (no "load more" needed).
# ----------------------------------------------------------------------------

sub _stationsRequest {
	my ( $client, $cb, $path ) = @_;

	my $key = 'rb_stations:' . $path;
	if ( my $stations = $cache->get($key) ) {
		return $cb->( _stationsFeed( $client, $stations ) );
	}

	_apiGet(
		$path,
		sub {
			my $stations = shift;
			$cache->set( $key, $stations, _cacheTTLSecs() );
			$cb->( _stationsFeed( $client, $stations ) );
		},
		sub { $cb->( _errorItems() ) },
	);
}

# ----------------------------------------------------------------------------
# Convert a Radio Browser station array into OPML audio items.
#
# Each station is a directly playable stream. Its url points at the Radio
# Browser click-tracking playlist endpoint /m3u/url/<uuid>: when the player
# fetches it the API registers a "click" and returns an M3U (Content-Type
# audio/mpegurl) containing the live stream, which LMS resolves and plays.
#
# IMPORTANT: url must be a plain STRING for the item to appear as a playable
# stream. A code reference here would make LMS render the station as a
# browsable folder instead of a track.
#
# Bitrate / codec / country are shown on line2 so the metadata is visible
# without an extra navigation step.
# ----------------------------------------------------------------------------

sub _stationsToOpml {
	my ( $client, $stations ) = @_;

	my @items;

	for my $s ( @{ $stations || [] } ) {
		next unless $s->{stationuuid} && $s->{name};
		next if _hideBroken() && defined $s->{lastcheckok} && $s->{lastcheckok} == 0;    # skip broken

		my @meta;
		push @meta, $s->{bitrate} . 'k' if $s->{bitrate};
		push @meta, uc $s->{codec}      if $s->{codec};
		push @meta, $s->{countrycode}   if $s->{countrycode};
		my $line2 = join( " \x{00B7} ", @meta );    # space-middot-space separator

		# Remember this station's metadata, keyed by both uuid and its play URL,
		# so the playlist-command observer can record it in Recently Played at
		# play time (the play URL is all we see at that point).
		my $play_url = $BASE_URL . '/m3u/url/' . _uri( $s->{stationuuid} );
		$cache->set( 'rb_meta:' . $s->{stationuuid}, _recentHash($s), META_TTL );

		push @items, {
			name      => $s->{name},
			line1     => $s->{name},
			line2     => $line2,
			type      => 'audio',
			# Click-tracking playlist endpoint -> counts a click and yields the
			# real stream. Plain string => LMS treats it as a playable track.
			# (A code reference here would make LMS render it as a folder.)
			# Plays are captured separately via a playlist-command observer that
			# matches this URL back to the station uuid (see _onPlaylistCmd).
			url       => $play_url,
			# Fall back to the plugin's bundled icon so grid tiles aren't blank
			# (and drop malformed favicon values that would render broken).
			image     => ( $s->{favicon} && $s->{favicon} =~ m{^https?://} )
			             ? $s->{favicon}
			             : 'plugins/RadioBrowser/html/images/icon.png',
			bitrate   => $s->{bitrate} ? $s->{bitrate} * 1000 : undef,
			on_select => 'play',    # explicit play-on-select hint
			playall   => 1,
		};
	}

	return @items ? \@items : [ { name => cstring( $client, 'PLUGIN_RADIOBROWSER_NONE' ), type => 'text' } ];
}

# ----------------------------------------------------------------------------
# Wrap a station list in a feed result that asks grid-capable UIs (Material
# skin, controller apps) to render the stations as large artwork tiles instead
# of a one-line text list. menuStyle 'album' + windowStyle 'icon_list' is the
# documented SlimBrowse hint (see slimbrowse.md <window_fields>).
# ----------------------------------------------------------------------------

sub _stationsFeed {
	my ( $client, $stations ) = @_;

	return {
		items  => _stationsToOpml( $client, $stations ),
		window => {
			menuStyle   => 'album',
			windowStyle => 'icon_list',
		},
	};
}

# ----------------------------------------------------------------------------
# Recently Played
#
# A locally stored, server-wide history of the last _recentCount() stations the
# user actually played. Plays are captured passively by _onPlaylistCmd, which
# observes playlist commands and matches the played /m3u/url/<uuid> URL back to
# a station. The list lives in the 'recent' pref so it survives server restarts.
# ----------------------------------------------------------------------------

# Observer for playlist play/load/add/insert commands. Pulls the played URL from
# the request, recovers the station uuid from our /m3u/url/<uuid> endpoint, and
# records it. Passive: it never changes playback, and never dies (a failure here
# must not disrupt the user's play action).
sub _onPlaylistCmd {
	my $request = shift;
	return unless $request;

	eval {
		# For playlist play/load/add/insert the played URL is the '_item' param.
		my $url = $request->getParam('_item');
		if ( defined $url && $url =~ m{/m3u/url/([0-9A-Za-z._~%-]+)} ) {
			recordRecent($1);
		}
	};
	$log->debug("Radio Browser: recent-capture error: $@") if $@;
}

# Top-level menu handler: render the stored history newest-first, with a Clear
# action on top. Stored entries are already station-shaped, so they flow back
# through the same rendering/playback path as every other station list.
sub recentStations {
	my ( $client, $cb, $args ) = @_;

	my $list = $prefs->get('recent') || [];
	@$list = @$list[ 0 .. _recentCount() - 1 ] if @$list > _recentCount();    # truncate on read

	my $items = _stationsToOpml( $client, $list );

	# Offer a Clear action only when there is real history (not the NONE item).
	# It carries an image so the grid-capable skins keep rendering large artwork
	# tiles: they fall back to a plain list as soon as one item lacks artwork.
	if ( @$list ) {
		unshift @$items, {
			name  => cstring( $client, 'PLUGIN_RADIOBROWSER_CLEAR_RECENT' ),
			type  => 'link',
			image => 'plugins/RadioBrowser/html/images/icon.png',
			url   => sub {
				my ( $c, $cb2 ) = @_;
				$prefs->set( 'recent', [] );
				recentStations( $c, $cb2 );
			},
		};
	}

	$cb->( {
		items  => $items,
		window => { menuStyle => 'album', windowStyle => 'icon_list' },
	} );
}

# Push a station (by uuid) onto the front of the recent list: dedupe by uuid so
# a re-play moves it to the top, then cap at _recentCount(). Called from the
# playlist-command observer; the LMS event loop is single-threaded so the
# read-modify-write needs no locking.
sub recordRecent {
	my $uuid = shift or return;

	my $meta = $cache->get( 'rb_meta:' . $uuid ) || { stationuuid => $uuid, name => $uuid };

	my $list = $prefs->get('recent') || [];
	@$list = grep { ( $_->{stationuuid} || '' ) ne $uuid } @$list;    # dedupe
	unshift @$list, $meta;                                            # newest first

	my $cap = _recentCount();
	@$list = @$list[ 0 .. $cap - 1 ] if @$list > $cap;               # cap on write

	$prefs->set( 'recent', $list );
}

# Minimal, YAML-safe station shape stored in the recent list and the uuid cache.
# lastcheckok is kept so the hideBroken filter in _stationsToOpml still applies.
sub _recentHash {
	my $s = shift;
	return {
		stationuuid => $s->{stationuuid},
		name        => $s->{name},
		bitrate     => $s->{bitrate},
		codec       => $s->{codec},
		countrycode => $s->{countrycode},
		favicon     => $s->{favicon},
		lastcheckok => $s->{lastcheckok},
	};
}

# Max stations remembered in Recently Played (settings-configurable, safe default).
sub _recentCount {
	my $n = $prefs->get('recentCount');
	return ( $n && $n =~ /^\d+$/ && $n > 0 ) ? $n : DEFAULT_RECENT_COUNT;
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Percent-encode a path/query component for the API URL.
sub _uri {
	my $s = shift;
	$s = '' unless defined $s;
	return uri_escape_utf8($s);
}

# Max stations to request per query (settings-configurable, with a safe default).
sub _maxResults {
	my $n = $prefs->get('maxResults');
	return ( $n && $n =~ /^\d+$/ && $n > 0 ) ? $n : DEFAULT_MAX_RESULTS;
}

# Max stations to request for the global Most Voted / Most Played charts. These
# are inherently "top N" lists, so this is kept small by default (settings-
# configurable): requesting the full directory here just blocks rendering.
sub _topResults {
	my $n = $prefs->get('topResults');
	return ( $n && $n =~ /^\d+$/ && $n > 0 ) ? $n : DEFAULT_TOP_RESULTS;
}

# Max tags to show in the Tags browse list (settings-configurable, with a safe default).
sub _maxTags {
	my $n = $prefs->get('maxTags');
	return ( $n && $n =~ /^\d+$/ && $n > 0 ) ? $n : DEFAULT_MAX_TAGS;
}

# Whether to hide stations that failed Radio Browser's last reachability check.
# Defaults to on so broken streams stay out of the listings unless the user opts
# in to showing them via the settings page.
sub _hideBroken {
	my $v = $prefs->get('hideBroken');
	return defined $v ? $v : 1;
}

# Query fragment appended to an existing '?...'-style query string to ask the API
# to omit broken stations. Empty when the user has chosen to show them.
sub _brokenSuffix {
	return _hideBroken() ? '&hidebroken=true' : '';
}

# Which top-level LMS menu the plugin registers under: 'radios' (default, the
# Radio menu) or 'apps' (the Apps/My Apps menu). Read once at initPlugin.
sub _menuLocation {
	my $v = $prefs->get('menuLocation');
	return ( defined $v && $v eq 'apps' ) ? 'apps' : 'radios';
}

# Station-result cache lifetime in seconds (pref stored in minutes).
sub _cacheTTLSecs {
	my $m = $prefs->get('cacheTTL');
	$m = ( $m && $m =~ /^\d+$/ && $m > 0 ) ? $m : DEFAULT_CACHE_TTL_MIN;
	return $m * 60;
}

# ----------------------------------------------------------------------------
# Country detection / resolution
# ----------------------------------------------------------------------------

# Return the active ( $code, $name ) for "local" content: the manual override
# pref if set, otherwise the auto-detected country. Empty list when unknown.
sub _activeCountry {
	my $override = $prefs->get('countryOverride');
	if ( defined $override && $override =~ /^\s*([A-Za-z]{2})\s*$/ ) {
		my $code = uc $1;
		return ( $code, _countryName($code) );
	}

	my $geo = $cache->get('radiobrowser_geo');
	if ( $geo && $geo->{code} ) {
		return ( $geo->{code}, $geo->{name} || _countryName( $geo->{code} ) );
	}

	return ();
}

# Map an ISO 3166-1 alpha-2 code to a display name using the cached countries
# list (populated by listCountries); fall back to the bare code.
sub _countryName {
	my $code = uc( shift || '' );
	return $code unless $code;

	my $countries = $cache->get('radiobrowser_countries');
	for my $c ( @{ $countries || [] } ) {
		return $c->{name} if $c->{name} && uc( $c->{iso_3166_1} || '' ) eq $code;
	}
	return $code;
}

# Kick off async geo-IP detection unless an override is set or we already have a
# cached result. Fire-and-forget: results land in the cache for later menus.
sub _maybeDetectCountry {
	return if $prefs->get('countryOverride');      # override wins; no lookup
	return if $cache->get('radiobrowser_geo');     # already known

	# Try each geo-IP provider in order until one returns a 2-letter country
	# code, then cache { code, name }. All failures are logged and swallowed so
	# the menu never depends on this succeeding.
	my @providers = GEO_PROVIDERS;
	_tryGeoProvider( \@providers );
}

sub _tryGeoProvider {
	my ( $providers ) = @_;

	my $p = shift @$providers;
	unless ( $p ) {
		$log->warn('country auto-detect failed: all geo-IP providers exhausted');
		return;
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $data = eval { JSON::XS::decode_json( $http->content ) };

			my $code = $data && $data->{ $p->{code} };
			if ( $code && $code =~ /^[A-Za-z]{2}$/ ) {
				$code = uc $code;
				my $name = ( $p->{name} && $data->{ $p->{name} } ) || _countryName($code);
				$cache->set( 'radiobrowser_geo', { code => $code, name => $name }, GEO_TTL );
				$log->info("country auto-detected: $code ($name) via $p->{url}");
				return;
			}

			$log->debug("geo-IP $p->{url} returned no usable country; trying next");
			_tryGeoProvider($providers);
		},
		sub {
			my ( $http, $error ) = @_;
			$log->debug("geo-IP $p->{url} failed: " . ( $error || 'unknown' ) . '; trying next');
			_tryGeoProvider($providers);
		},
		{ timeout => 10 },
	)->get( $p->{url}, 'User-Agent' => USER_AGENT );
}

1;
