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

# JSON decoder. LMS bundles JSON::XS; we keep a single entry point so all
# decoding is wrapped in eval for robust error handling.
use JSON::XS ();

use constant USER_AGENT  => 'LyrionRadioBrowserPlugin/1.0';
use constant DNS_NAME    => 'all.api.radio-browser.info';
use constant FALLBACK_URL => 'https://all.api.radio-browser.info';
use constant LIST_TTL    => 86400;    # cache tags/countries for 1 day
use constant RESULT_LIMIT => 100;     # max stations per result list

# Logger category - configurable under Settings > Advanced > Logging.
my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.radiobrowser',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_RADIOBROWSER',
});

my $cache;

# Base URL for this server session, chosen once at init.
my $BASE_URL = FALLBACK_URL;

# ----------------------------------------------------------------------------
# Plugin lifecycle
# ----------------------------------------------------------------------------

sub initPlugin {
	my $class = shift;

	$cache = Slim::Utils::Cache->new();

	# Pick an API mirror via DNS round-robin (one-time, at startup).
	$BASE_URL = _resolveBaseUrl();
	$log->info("Radio Browser using base URL: $BASE_URL");

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

	$cb->({
		items => [
			{
				name  => cstring( $client, 'PLUGIN_RADIOBROWSER_SEARCH' ),
				type  => 'search',
				url   => \&searchStations,
			},
			{
				name  => cstring( $client, 'PLUGIN_RADIOBROWSER_TOP' ),
				type  => 'link',
				items => [
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
				],
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
		],
	});
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
		. '?limit=' . RESULT_LIMIT . '&hidebroken=true&order=votes&reverse=true';

	_apiGet(
		$path,
		sub { $cb->( { items => _stationsToOpml( $client, shift ) } ) },
		sub { $cb->( _errorItems() ) },
	);
}

# ----------------------------------------------------------------------------
# Top stations (most voted or most clicked).
# ----------------------------------------------------------------------------

sub topStations {
	my ( $client, $cb, $args, $pt ) = @_;

	my $order = ( $pt && $pt->{order} ) || 'topvote';
	my $path  = "/json/stations/$order/" . RESULT_LIMIT . '?hidebroken=true';

	_apiGet(
		$path,
		sub { $cb->( { items => _stationsToOpml( $client, shift ) } ) },
		sub { $cb->( _errorItems() ) },
	);
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
		'/json/tags?order=stationcount&reverse=true&limit=200&hidebroken=true',
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
		. '?limit=' . RESULT_LIMIT . '&hidebroken=true&order=votes&reverse=true';

	_apiGet(
		$path,
		sub { $cb->( { items => _stationsToOpml( $client, shift ) } ) },
		sub { $cb->( _errorItems() ) },
	);
}

# ----------------------------------------------------------------------------
# Country list -> drill into stations for the chosen country code.
# ----------------------------------------------------------------------------

sub listCountries {
	my ( $client, $cb, $args ) = @_;

	my $cached = $cache->get('radiobrowser_countries');
	return $cb->( { items => _countryItems( $client, $cached ) } ) if $cached;

	_apiGet(
		'/json/countries?order=name&hidebroken=true',
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

	my $code = ( $pt && $pt->{code} ) || '';
	my $path = '/json/stations/bycountrycodeexact/' . _uri( $code )
		. '?limit=' . RESULT_LIMIT . '&hidebroken=true&order=votes&reverse=true';

	_apiGet(
		$path,
		sub { $cb->( { items => _stationsToOpml( $client, shift ) } ) },
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
		next if defined $s->{lastcheckok} && $s->{lastcheckok} == 0;    # skip broken

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
			image     => $s->{favicon} || undef,
			bitrate   => $s->{bitrate} ? $s->{bitrate} * 1000 : undef,
			on_select => 'play',    # explicit play-on-select hint
			playall   => 1,
		};
	}

	return @items ? \@items : [ { name => cstring( $client, 'PLUGIN_RADIOBROWSER_NONE' ), type => 'text' } ];
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

1;
