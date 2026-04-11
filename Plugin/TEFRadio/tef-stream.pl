#!/usr/bin/env perl
# tef-stream.pl — TEF FM Radio streaming helper for the Lyrion LMS plugin
# -------------------------------------------------------------------------
# Usage:
#   perl tef-stream.pl <serial_port> <freq_hz> <alsa_device> [bitrate_k]
#
# What it does:
#   1. Opens the TEF tuner's serial port and sends a tune command.
#   2. Waits briefly for the hardware to settle.
#   3. Replaces itself (exec) with ffmpeg, which reads audio from the
#      USB ALSA capture device and encodes it as MP3 on stdout.
#
# LMS reads the MP3 stream directly from this process's stdout via a pipe.
# No Icecast server is required.
#
# Dependencies:
#   - ffmpeg (with libmp3lame)
#   - Perl 5 (standard modules only: POSIX, Fcntl)

use strict;
use warnings;
use POSIX ();
use Fcntl qw(O_WRONLY O_NOCTTY);

unless (@ARGV >= 3) {
    print STDERR
        "Usage: tef-stream.pl <serial_port> <freq_hz> <alsa_device> [bitrate_k]\n",
        "Example: tef-stream.pl /dev/ttyACM0 90800000 hw:CARD=Tuner,DEV=0 192k\n";
    exit 1;
}

my ($port, $freq_hz, $alsa_dev, $bitrate) = @ARGV;
$bitrate //= '192k';

my $freq_khz = int($freq_hz / 1000);

# ── 1. Tune hardware ──────────────────────────────────────────────────────
_tune($port, $freq_khz);

# Hardware needs a short moment to switch frequency cleanly
select(undef, undef, undef, 0.35);

# ── 2. Stream audio → stdout ──────────────────────────────────────────────
# exec() replaces this Perl process with ffmpeg, inheriting stdout.
# LMS is holding the read end of the pipe connected to our stdout.
exec(
    'ffmpeg',
    '-loglevel', 'error',
    '-f',        'alsa',
    '-i',        $alsa_dev,
    '-c:a',      'libmp3lame',
    '-b:a',      $bitrate,
    '-f',        'mp3',
    'pipe:1',           # write MP3 to stdout
) or die "tef-stream: cannot exec ffmpeg: $!\n";


sub _tune {
    my ($port, $freq_khz) = @_;
    my $cmd = "T${freq_khz}\n";

    # Configure serial port: 115200 8N1 raw
    system('stty', '-F', $port,
        qw(115200 cs8 -cstopb -parenb raw -echo));

    # Open the tty without becoming controlling terminal, write command
    if (sysopen(my $tty, $port, O_WRONLY | O_NOCTTY)) {
        syswrite($tty, $cmd);
        POSIX::tcdrain(fileno($tty));
        close($tty);
    } else {
        warn "tef-stream: warning: could not open $port: $!\n";
        # Continue — audio device may already be on the right frequency
    }
}
