package Plugins::TEFRadio::ProtocolHandler;

# Protocol handler for tefradio:// URLs.
#
# When Lyrion plays e.g. tefradio://90.8 this handler:
#
#   1. new() — spawns tef-stream.pl as a child process:
#                  perl tef-stream.pl <port> <freq_hz> <alsa_dev> <bitrate>
#              tef-stream.pl tunes the TEF tuner via serial, then exec()s into
#              ffmpeg which encodes the USB audio to MP3 on stdout.
#
#   2. Returns the read end of the pipe to LMS.
#      LMS uses fileno() + select() to know when data is ready, then
#      sysread()s MP3 chunks and sends them to the player.
#
#   3. On stop / station change, LMS closes the handle; the write end of
#      the pipe breaks (EPIPE) and ffmpeg exits cleanly.
#
# No Icecast server is required. Audio goes:
#   ALSA (TEF USB) → ffmpeg → pipe → LMS server → Squeezebox / squeezelite

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use File::Spec::Functions qw(catfile);
use Scalar::Util qw(blessed);

my $log   = logger('plugin.tefradio');
my $prefs = preferences('plugin.tefradio');

# ─── Protocol capabilities ────────────────────────────────────────────────────

sub isRemote        { 1 }   # Treated as a live stream (no seeking)
sub canSeek         { 0 }
sub isRewindable    { 0 }
sub canDirectStream { 0 }   # Always proxy through the LMS server
sub getFormatForURL { 'mp3' }
sub contentType     { 'mp3' }

# ─── Stream construction ──────────────────────────────────────────────────────

sub new {
    my ($class, $args) = @_;

    my $song = $args->{song};
    my $url  = $song->currentTrack()->url();    # tefradio://90.8

    my ($freq_str) = $url =~ m{^tefradio://(.+)$};
    unless (defined $freq_str && $freq_str =~ /^\d+\.?\d*$/) {
        $log->error("TEFRadio: malformed URL: $url");
        return undef;
    }

    # Accept both MHz (90.8) and Hz (90800000)
    my $freq_hz = ($freq_str < 2200)
        ? int($freq_str * 1_000_000)
        : int($freq_str);

    my $port    = $prefs->get('serial_port')  // '/dev/ttyACM0';
    my $device  = $prefs->get('audio_device') // 'hw:CARD=Tuner,DEV=0';
    my $bitrate = $prefs->get('bitrate')       // '192k';
    my $script  = catfile(_plugin_dir(), 'tef-stream.pl');

    unless (-f $script) {
        $log->error("TEFRadio: tef-stream.pl not found at $script");
        return undef;
    }

    $log->info(sprintf(
        "TEFRadio: starting stream — %.1f MHz, port=%s, device=%s",
        $freq_hz / 1_000_000, $port, $device
    ));

    # Fork tef-stream.pl; our $fh is the read end of its stdout pipe.
    # tef-stream.pl will tune the hardware, then exec() into ffmpeg.
    # ffmpeg writes MP3 frames to the pipe continuously.
    open(my $fh, '-|', $^X, $script, $port, $freq_hz, $device, $bitrate)
        or do {
            $log->error("TEFRadio: cannot spawn tef-stream.py: $!");
            return undef;
        };

    # Bless the IO::File handle as our class.
    # LMS calls fileno($self) to register with select(), then sysread() for data.
    # Both delegate to the underlying filehandle automatically.
    bless $fh, $class;
    return $fh;
}

# Explicit wrappers so LMS method-call style (->fileno, ->sysread) works too.

sub fileno {
    my $self = shift;
    return CORE::fileno($self);
}

sub sysread {
    my ($self, undef, $maxlen, $offset) = @_;
    return CORE::sysread($self, $_[1], $maxlen, $offset // 0);
}

sub read {
    my ($self, undef, $maxlen, $offset) = @_;
    return CORE::read($self, $_[1], $maxlen, $offset // 0);
}

sub close {
    my $self = shift;
    CORE::close($self);
}

# ─── Metadata ─────────────────────────────────────────────────────────────────

sub getMetadataFor {
    my ($class, $client, $url) = @_;

    my ($freq_str) = $url =~ m{^tefradio://(.+)$};
    my $freq_mhz   = defined $freq_str ? ($freq_str + 0) : 0;

    # Try to find a matching preset name
    my $stations = $prefs->get('stations') || [];
    my ($match)  = grep { abs($_->{freq} - $freq_mhz) < 0.05 } @$stations;
    my $title    = $match ? $match->{name} : sprintf('FM %.1f MHz', $freq_mhz);

    return {
        title  => $title,
        artist => sprintf('%.1f MHz', $freq_mhz),
        album  => 'TEF FM Radio',
        cover  => undef,
        icon   => Slim::Player::ProtocolHandlers->iconForURL($url),
        type   => 'FM Radio',
    };
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

sub getIcon {
    return Plugins::TEFRadio::Plugin->getIcon();
}

sub _plugin_dir {
    # Locate our plugin directory using %INC (set when Perl loads this module)
    if (my $path = $INC{'Plugins/TEFRadio/ProtocolHandler.pm'}) {
        $path =~ s{/ProtocolHandler\.pm$}{};
        return $path;
    }
    # Fallback: search LMS plugin directories
    for my $dir (Slim::Utils::OSDetect::dirsFor('Plugins')) {
        return catfile($dir, 'TEFRadio') if -d catfile($dir, 'TEFRadio');
    }
    return '.';
}

1;
