#!/usr/bin/env perl
# tef-stream.pl — TEF FM/AM Radio streaming helper for the Lyrion LMS plugin
# -------------------------------------------------------------------------
# Usage:
#   perl tef-stream.pl <serial_port> <freq_khz> <alsa_device> [bitrate_k]
#
# What it does:
#   1. Opens the TEF tuner's serial port and performs the startup handshake.
#   2. Sends a tune command — firmware auto-selects FM or AM by range:
#        65000–108000 kHz → FM,  144–30000 kHz → AM (LW/MW/SW)
#   3. Replaces itself (exec) with ffmpeg, which reads audio from the
#      USB ALSA capture device and encodes it as MP3 on stdout.
#
# LMS reads the MP3 stream directly from this process's stdout via a pipe.
# No Icecast server is required.
#
# Dependencies:
#   - ffmpeg (with libmp3lame)
#   - Perl 5 core modules only: POSIX, Fcntl, IO::Select

use strict;
use warnings;
use POSIX ();
use Fcntl   qw(O_RDWR O_NOCTTY);
use IO::Select;

unless (@ARGV >= 3) {
    print STDERR
        "Usage: tef-stream.pl <serial_port> <freq_khz> <alsa_device> [bitrate_k]\n",
        "  FM example: tef-stream.pl /dev/ttyACM0 90800  hw:CARD=Tuner,DEV=0 192k\n",
        "  AM example: tef-stream.pl /dev/ttyACM0 810    hw:CARD=Tuner,DEV=0 192k\n";
    exit 1;
}

my ($port, $freq_khz, $alsa_dev, $bitrate) = @ARGV;
$bitrate  //= '192k';
$freq_khz   = int($freq_khz);

# Write our PID immediately so ProtocolHandler can kill us on station change.
# exec() preserves the PID, so this stays valid after we exec ffmpeg.
my $_pidfile = '/tmp/tefradio-stream.pid';
if (open my $_pf, '>', $_pidfile) { print $_pf $$; close $_pf }

# Locate ffmpeg: prefer system PATH, fall back to the bundled static binary
# that lives alongside this script in the plugin directory.
my $ffmpeg = do {
    my $bundled = __FILE__;
    $bundled =~ s{[^/]+$}{ffmpeg};
    (-x $bundled) ? $bundled : 'ffmpeg';
};

# ── 1. Tune hardware ──────────────────────────────────────────────────────
_tune($port, $freq_khz);

# Hardware needs a short moment to switch frequency cleanly
select(undef, undef, undef, 0.35);

# ── 2. Stream audio → stdout ──────────────────────────────────────────────
# exec() replaces this Perl process with ffmpeg, inheriting stdout.
# LMS is holding the read end of the pipe connected to our stdout.
exec(
    $ffmpeg,
    '-loglevel', 'error',
    '-f',        'alsa',
    '-i',        $alsa_dev,
    '-c:a',      'libmp3lame',
    '-b:a',      $bitrate,
    '-f',        'mp3',
    'pipe:1',
) or die "tef-stream: cannot exec ffmpeg ($ffmpeg): $!\n";


sub _tune {
    my ($port, $freq_khz) = @_;

    # Configure serial port: 115200 8N1 raw
    system('stty', '-F', $port,
        qw(115200 cs8 -cstopb -parenb raw -echo));

    # Open R/W — we need to read back the OK from the startup handshake
    my $tty;
    unless (sysopen($tty, $port, O_RDWR | O_NOCTTY)) {
        warn "tef-stream: warning: could not open $port: $!\n";
        return;  # Continue — device may already be tuned to the right frequency
    }

    # Startup handshake: firmware requires 'x\n' before accepting commands.
    # Safe to send even if already running — firmware just echoes OK again.
    syswrite($tty, "x\n");
    _wait_for_ok($tty);

    # Tune to frequency. Firmware auto-selects band by range:
    #   65000–108000 kHz → FM,  144–30000 kHz → AM
    syswrite($tty, "T${freq_khz}\n");
    POSIX::tcdrain(fileno($tty));
    close($tty);
}

sub _wait_for_ok {
    my ($fh) = @_;
    my $sel  = IO::Select->new($fh);
    my $buf  = '';
    my $dead = time() + 3;

    while (time() < $dead) {
        my $left  = $dead - time();
        my @ready = $sel->can_read($left < 0.5 ? $left : 0.5);
        next unless @ready;
        my $n = sysread($fh, my $chunk, 128);
        next unless defined $n && $n > 0;
        $buf .= $chunk;
        return 1 if $buf =~ /OK/;
    }
    warn "tef-stream: warning: no OK from tuner startup (continuing anyway)\n";
    return 0;
}
