#!/usr/bin/env perl
# tef-stream.pl — TEF FM/AM Radio streaming helper for the Lyrion LMS plugin
# -------------------------------------------------------------------------
# Usage (called by LMS transcoder via custom-convert.conf):
#   perl tef-stream.pl <url_or_freq> <serial_port> <alsa_device> [bitrate_k]
#
#   <url_or_freq> : either a tefradio:// URL (e.g. tefradio://90.8)
#                   or a raw frequency in kHz (e.g. 90800) for compatibility
#
# What it does:
#   1. Kills any existing RDS reader (frees the serial port).
#   2. Opens the TEF tuner's serial port and tunes to the given frequency.
#   3. Spawns tef-rds.pl as a double-forked background daemon.
#   4. Replaces itself (exec) with ffmpeg, which reads audio from the
#      USB ALSA capture device and encodes it as MP3 on stdout.
#
# LMS reads the MP3 stream from this process's stdout via the transcoder pipe.

use strict;
use warnings;
use POSIX ();
use Fcntl   qw(O_RDWR O_NOCTTY);
use IO::Select;

unless (@ARGV >= 3) {
    print STDERR
        "Usage: tef-stream.pl <url_or_freq> <serial_port> <alsa_device> [bitrate_k]\n",
        "  FM: tef-stream.pl tefradio://90.8  /dev/ttyACM0 hw:CARD=Tuner,DEV=0 192k\n",
        "  AM: tef-stream.pl tefradio://810   /dev/ttyACM0 hw:CARD=Tuner,DEV=0 192k\n";
    exit 1;
}

my ($url_or_freq, $port, $alsa_dev, $bitrate) = @ARGV;
$bitrate //= '192k';

# Accept both tefradio:// URL and raw freq_khz integer
my $freq_khz;
if (defined $url_or_freq && $url_or_freq =~ m{^tefradio://(.+)$}) {
    $freq_khz = _url_to_khz($1);
    die "tef-stream: invalid frequency in URL: $url_or_freq\n"
        unless defined $freq_khz;
} else {
    $freq_khz = int($url_or_freq // 0);
}

# Locate this script's directory to find tef-rds.pl alongside it
(my $script_dir = __FILE__) =~ s{[^/]+$}{};
$script_dir =~ s{/$}{} if $script_dir ne '/';
my $rds_script = "$script_dir/tef-rds.pl";

# Locate ffmpeg: prefer bundled static binary next to this script
my $ffmpeg = do {
    my $bundled = "$script_dir/ffmpeg";
    (-x $bundled) ? $bundled : 'ffmpeg';
};

# ── 1. Kill all running RDS readers (any frequency) ──────────────────────
# The previous station's RDS reader holds the serial port; kill it so we
# can tune without interference.
my $rds_pidfile = "/tmp/tefradio-rds-${freq_khz}.json.pid";
for my $pf (glob('/tmp/tefradio-rds-*.json.pid')) {
    _kill_rds($pf);
}

# ── 2. Tune hardware ──────────────────────────────────────────────────────
_tune($port, $freq_khz);

# Hardware needs a short moment to switch frequency cleanly
select(undef, undef, undef, 0.35);

# ── 3. Spawn RDS reader in background ────────────────────────────────────
if (-f $rds_script) {
    my $json_file = "/tmp/tefradio-rds-${freq_khz}.json";
    _spawn_rds($rds_script, $port, $freq_khz, $json_file, $rds_pidfile);
}

# ── 4. Stream audio → stdout ──────────────────────────────────────────────
# exec() replaces this Perl process with ffmpeg, inheriting stdout.
# LMS is holding the read end of the transcoder pipe connected to our stdout.
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


# ── Subroutines ───────────────────────────────────────────────────────────

sub _kill_rds {
    my ($pidfile) = @_;
    return unless -f $pidfile;
    if (open my $fh, '<', $pidfile) {
        my $pid = <$fh>; chomp $pid;
        close $fh;
        kill('TERM', $pid) if $pid =~ /^\d+$/;
    }
    unlink $pidfile;
}

sub _spawn_rds {
    my ($script, $port, $freq_khz, $json_file, $pidfile) = @_;

    # Double-fork: grandchild re-parents to init, keeping the parent process clean.
    my $pid = fork();
    return unless defined $pid;

    if ($pid == 0) {
        my $gc = fork();
        POSIX::_exit(defined $gc ? 0 : 1) if !defined $gc || $gc != 0;

        POSIX::setsid();
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec($^X, $script, $port, $freq_khz, $json_file);
        POSIX::_exit(1);
    }

    waitpid($pid, 0);
}

sub _tune {
    my ($port, $freq_khz) = @_;

    system('stty', '-F', $port,
        qw(115200 cs8 -cstopb -parenb raw -echo));

    my $tty;
    unless (sysopen($tty, $port, O_RDWR | O_NOCTTY)) {
        warn "tef-stream: warning: could not open $port: $!\n";
        return;
    }

    syswrite($tty, "x\n");
    _wait_for_ok($tty);

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

sub _url_to_khz {
    my ($freq_str) = @_;
    my $f = $freq_str + 0;
    if ($freq_str =~ /\./ || ($f >= 65 && $f < 144)) {
        return int($f * 1000 + 0.5);
    } elsif ($f >= 65000 && $f <= 108000) {
        return int($f);
    } elsif ($f >= 144 && $f <= 30000) {
        return int($f);
    }
    return undef;
}
