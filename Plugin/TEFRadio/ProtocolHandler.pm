package Plugins::TEFRadio::ProtocolHandler;

# Protocol handler for tefradio:// URLs.
#
# When Lyrion plays e.g. tefradio://90.8 (FM) or tefradio://810 (AM) this handler:
#
#   1. new() — spawns tef-stream.pl as a child process:
#                  perl tef-stream.pl <port> <freq_khz> <alsa_dev> <bitrate>
#              tef-stream.pl does the startup handshake, tunes the TEF tuner via
#              serial, then exec()s into ffmpeg which encodes the USB audio to
#              MP3 on stdout.
#
#   2. Returns the read end of the pipe to LMS.
#      LMS uses fileno() + select() to know when data is ready, then
#      sysread()s MP3 chunks and sends them to the player.
#
#   3. On stop / station change, LMS closes the handle; the write end of
#      the pipe breaks (EPIPE) and ffmpeg exits cleanly.
#
# URL frequency conventions:
#   tefradio://90.8    — FM 90.8 MHz  (decimal → MHz)
#   tefradio://100     — FM 100 MHz   (integer 65–108 → MHz)
#   tefradio://90800   — FM 90.8 MHz  (integer ≥65000 → kHz)
#   tefradio://810     — AM 810 kHz   (integer 144–30000 → kHz AM)
#   tefradio://198     — AM 198 kHz   (LW)
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
    my $url  = $song->currentTrack()->url();    # e.g. tefradio://90.8

    my ($freq_str) = $url =~ m{^tefradio://(.+)$};
    unless (defined $freq_str && $freq_str =~ /^\d+\.?\d*$/) {
        $log->error("TEFRadio: malformed URL: $url");
        return undef;
    }

    my $freq_khz = _url_to_khz($freq_str);
    unless (defined $freq_khz) {
        $log->error("TEFRadio: frequency out of supported range: $freq_str");
        return undef;
    }

    my $port    = $prefs->get('serial_port')  // '/dev/ttyACM0';
    my $device  = $prefs->get('audio_device') // 'hw:CARD=Tuner,DEV=0';
    my $bitrate = $prefs->get('bitrate')       // '192k';
    my $script  = catfile(_plugin_dir(), 'tef-stream.pl');

    unless (-f $script) {
        $log->error("TEFRadio: tef-stream.pl not found at $script");
        return undef;
    }

    $log->info(sprintf(
        "TEFRadio: starting stream — %s, port=%s, device=%s",
        _khz_label($freq_khz), $port, $device
    ));

    # Fork tef-stream.pl; our $fh is the read end of its stdout pipe.
    # tef-stream.pl does the startup handshake, tunes the hardware, then
    # exec()s into ffmpeg. ffmpeg writes MP3 frames to the pipe continuously.
    open(my $fh, '-|', $^X, $script, $port, $freq_khz, $device, $bitrate)
        or do {
            $log->error("TEFRadio: cannot spawn tef-stream.pl: $!");
            return undef;
        };

    # Bless the IO::File handle as our class.
    # LMS calls fileno($self) to register with select(), then sysread() for data.
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
    my $freq_khz   = defined $freq_str ? _url_to_khz($freq_str) : undef;
    my $label      = defined $freq_khz ? _khz_label($freq_khz) : 'Radio';

    # Try to find a matching preset name
    my $stations = $prefs->get('stations') || [];
    my ($match)  = grep { _station_matches($_, $freq_khz) } @$stations;
    my $title    = $match ? $match->{name} : "TEF Radio $label";

    return {
        title  => $title,
        artist => $label,
        album  => 'TEF FM/AM Radio',
        cover  => undef,
        icon   => Slim::Player::ProtocolHandlers->iconForURL($url),
        type   => defined($freq_khz) && $freq_khz >= 65000 ? 'FM Radio' : 'AM Radio',
    };
}

# ─── Frequency helpers ────────────────────────────────────────────────────────

# Convert a URL frequency string to kHz.
# Returns undef if the value is out of all supported ranges.
#
#   Decimal (90.8)         → FM MHz  → 90800 kHz
#   Integer 65–108         → FM MHz  → e.g. 100 → 100000 kHz
#   Integer 65000–108000   → FM kHz  → passed through
#   Integer 144–30000      → AM kHz  → passed through (LW/MW/SW)
sub _url_to_khz {
    my ($freq_str) = @_;
    my $f = $freq_str + 0;

    if ($freq_str =~ /\./ || ($f >= 65 && $f < 144)) {
        # Has decimal, or small integer in FM-only zone → treat as MHz
        return int($f * 1000 + 0.5);
    } elsif ($f >= 65000 && $f <= 108000) {
        # Large integer in FM kHz range
        return int($f);
    } elsif ($f >= 144 && $f <= 30000) {
        # AM range in kHz (LW 144–283, MW 520–1710, SW up to 30 MHz)
        return int($f);
    }
    return undef;
}

# Human-readable label for a kHz value.
sub _khz_label {
    my ($freq_khz) = @_;
    return $freq_khz >= 10000
        ? sprintf('%.1f MHz', $freq_khz / 1000)
        : sprintf('%d kHz',   $freq_khz);
}

# Does a stored station preset match a given freq_khz?
# Presets store FM as MHz (65–108) and AM as kHz (144–30000).
sub _station_matches {
    my ($station, $freq_khz) = @_;
    return 0 unless defined $freq_khz;
    my $f = $station->{freq};
    my $station_khz = ($f >= 65 && $f <= 108)
        ? int($f * 1000 + 0.5)
        : int($f);
    return abs($station_khz - $freq_khz) < 10;
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

sub getIcon {
    return Plugins::TEFRadio::Plugin->getIcon();
}

sub _plugin_dir {
    if (my $path = $INC{'Plugins/TEFRadio/ProtocolHandler.pm'}) {
        $path =~ s{/ProtocolHandler\.pm$}{};
        return $path;
    }
    for my $dir (Slim::Utils::OSDetect::dirsFor('Plugins')) {
        return catfile($dir, 'TEFRadio') if -d catfile($dir, 'TEFRadio');
    }
    return '.';
}

1;
