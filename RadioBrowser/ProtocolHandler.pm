package Plugins::RadioBrowser::ProtocolHandler;

# ----------------------------------------------------------------------------
# Protocol handler for the radiobrowser:// scheme.
#
# Station OPML items use a plain "radiobrowser://<uuid>" url so LMS renders them
# as directly playable tracks (a code-ref url would make them browsable folders
# instead). Routing playback through our own scheme gives us the play callback
# the plain m3u url never provided: at play time we (a) record the station in
# the Recently Played list and (b) resolve the uuid to a live stream via Radio
# Browser's /json/url/<uuid> click-tracking endpoint.
#
# We subclass the stock HTTP handler so, once getNextTrack() has set the real
# stream url on the song, all the actual streaming is handled by LMS as usual.
# ----------------------------------------------------------------------------

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

use Slim::Utils::Log;

my $log = Slim::Utils::Log->getLogger('plugin.radiobrowser');

# Extract the station uuid from a radiobrowser://<uuid> url.
sub _uuid {
	my $url = shift;
	return ( defined $url && $url =~ m{^radiobrowser://([0-9A-Za-z-]+)} ) ? $1 : undef;
}

sub isRemote { 1 }

# Skip remote URL scanning: the stock HTTP handler would try to HTTP-fetch our
# radiobrowser:// pseudo-url here and fail. There is nothing to resolve at scan
# time — the uuid is turned into a real stream later, in getNextTrack().
sub scanUrl {
	my ( $class, $url, $args ) = @_;
	$args->{cb}->( $args->{song}->currentTrack );
}

# Stream through the server rather than letting the player fetch directly: the
# player can't open a radiobrowser:// url, and proxying the resolved stream is
# the simplest reliable path for internet radio.
sub canDirectStream { 0 }

# Called by LMS just before playback. Record the play, then resolve the uuid to
# a real stream url and hand it back via the song so the parent HTTP handler can
# stream it.
sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;

	my $url  = $song->currentTrack->url;
	my $uuid = _uuid($url);

	unless ( $uuid ) {
		$log->error( 'invalid radiobrowser url: ' . ( $url || '?' ) );
		return $errorCb->('invalid radiobrowser url');
	}

	Plugins::RadioBrowser::Plugin::recordRecent($uuid);

	Plugins::RadioBrowser::Plugin::resolveStreamUrl(
		$uuid,
		sub {
			my $streamUrl = shift;
			$song->streamUrl($streamUrl);
			$successCb->();
		},
		sub {
			my $error = shift;
			$log->error( "could not resolve radiobrowser://$uuid: " . ( $error || 'unknown' ) );
			$errorCb->( $error || 'resolve failed' );
		},
	);
}

# Now-playing title / artwork / bitrate, taken from the cached station metadata.
sub getMetadataFor {
	my ( $class, $client, $url ) = @_;
	my $uuid = _uuid($url) or return {};
	return Plugins::RadioBrowser::Plugin::recentMetaFor($uuid);
}

1;
