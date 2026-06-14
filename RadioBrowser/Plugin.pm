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

# JSON decoder. LMS bundles JSON::XS; we keep a single entry point so all
# decoding is wrapped in eval for robust error handling.
use JSON::XS ();

use constant USER_AGENT  => 'LyrionRadioBrowserPlugin/1.0';
use constant DNS_NAME    => 'all.api.radio-browser.info';
use constant FALLBACK_URL => 'https://all.api.radio-browser.info';
use constant LIST_TTL    => 86400;    # cache tags/countries for 1 day
use constant GEO_TTL     => 604800;   # cache detected country for 7 days
# Defaults for the user-configurable station result cap / cache lifetime
# (overridable via the settings page; see _maxResults / _cacheTTLSecs).
use constant DEFAULT_MAX_RESULTS   => 5000;   # effectively "all"; bounds worst-case size
use constant DEFAULT_CACHE_TTL_MIN => 60;     # cache station result lists for 1 hour

# IP-geolocation providers, tried in order until one yields a 2-letter country
# code. LMS has no built-in country pref, so we infer it from the server's
# public IP. Each entry maps the provider's JSON fields to code/name.
use constant GEO_PROVIDERS => (
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
		cacheTTL        => DEFAULT_CACHE_TTL_MIN,
		hideBroken      => 1,
	});

	# Keep the numeric prefs sane: positive integers within practical bounds.
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 100000 }, 'maxResults');
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 10080   }, 'cacheTTL');

	# Pick an API mirror via DNS round-robin (one-time, at startup).
	$BASE_URL = _resolveBaseUrl();
	$log->info("Radio Browser using base URL: $BASE_URL");

	# Web settings page for the manual country override (web UI only).
	if ( main::WEBUI ) {
		require Plugins::RadioBrowser::Settings;
		Plugins::RadioBrowser::Settings->new;
	}

	# Auto-detect the listener's country in the background (unless overridden).
	_maybeDetectCountry();

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'radiobrowser',
		menu   => 'radios',        # appear under the LMS "Radio" menu
		is_app => 0,
		weight => 50,
	);
}

sub getDisplayName { 'PLUGIN_RADIOBROWSER' }

# ----------------------------------------------------------------------------
# DNS load balancing (CLAUDE.md sec 3.1) with graceful fallback.
#
# Resolve A records for all.api.radio-browser.info, pick one at random, then
# reverse-resolve it to a real mirror hostname (e.g. de1.api.radio-browser.info)
# so the HTTPS Host header / TLS SNI stay valid. If Net::DNS is unavailable or
# anything fails, fall back to the round-robin hostname directly.
# ----------------------------------------------------------------------------

sub _resolveBaseUrl {
	my $url = eval {
		require Net::DNS;

		my $resolver = Net::DNS::Resolver->new( tcp_timeout => 5, udp_timeout => 5 );
		my $reply    = $resolver->query( DNS_NAME, 'A' )
			or die "no A records for " . DNS_NAME . "\n";

		my @ips = map { $_->address } grep { $_->type eq 'A' } $reply->answer;
		die "empty A record set\n" unless @ips;

		# Random selection spreads load across mirrors per the API guidelines.
		my $ip = $ips[ int( rand( scalar @ips ) ) ];

		# Reverse-resolve so TLS certificate validation has a matching hostname.
		my $host;
		if ( my $ptr = $resolver->query( $ip, 'PTR' ) ) {
			($host) = map { my $h = $_->ptrdname; $h =~ s/\.$//; $h }
				grep { $_->type eq 'PTR' } $ptr->answer;
		}

		die "no PTR for $ip\n" unless $host;
		return "https://$host";
	};

	if ( $@ || !$url ) {
		$log->warn( "DNS round-robin unavailable (" . ( $@ || 'unknown' ) . "); falling back to " . FALLBACK_URL );
		return FALLBACK_URL;
	}

	return $url;
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
	my $path  = "/json/stations/$order/" . _maxResults();
	$path .= '?hidebroken=true' if _hideBroken();

	_stationsRequest( $client, $cb, $path );
}

# ----------------------------------------------------------------------------
# Tag / genre list -> drill into stations for the chosen tag.
# ----------------------------------------------------------------------------

sub listTags {
	my ( $client, $cb, $args ) = @_;

	my $cached = $cache->get('radiobrowser_tags');
	return $cb->( { items => _tagItems( $client, $cached ) } ) if $cached;

	# Limit to popular tags to keep the list usable on a remote/IR UI.
	_apiGet(
		'/json/tags?order=stationcount&reverse=true&limit=200' . _brokenSuffix(),
		sub {
			my $tags = shift;
			$cache->set( 'radiobrowser_tags', $tags, LIST_TTL );
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

		push @items, {
			name      => $s->{name},
			line1     => $s->{name},
			line2     => $line2,
			type      => 'audio',
			# Click-tracking playlist endpoint -> counts a click and yields the
			# real stream. Plain string => LMS treats it as a playable track.
			# (A code reference here would make LMS render it as a folder.)
			url       => $BASE_URL . '/m3u/url/' . _uri( $s->{stationuuid} ),
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
# Helpers
# ----------------------------------------------------------------------------

# Percent-encode a path/query component for the API URL.
sub _uri {
	my $s = shift;
	$s = '' unless defined $s;
	$s =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;
	return $s;
}

# Max stations to request per query (settings-configurable, with a safe default).
sub _maxResults {
	my $n = $prefs->get('maxResults');
	return ( $n && $n =~ /^\d+$/ && $n > 0 ) ? $n : DEFAULT_MAX_RESULTS;
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
				my $name = ( $data->{ $p->{name} } ) || _countryName($code);
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
