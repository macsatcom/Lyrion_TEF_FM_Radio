#!/usr/bin/env perl
# tef-stream.pl — TEF FM/AM Radio streaming helper for the Lyrion LMS plugin
# -------------------------------------------------------------------------
# Usage (called by LMS transcoder via custom-convert.conf):
#   perl tef-stream.pl <url_or_freq> <serial_port> <alsa_device> [bitrate_k]
#
# What it does — every time it is called:
#   1. Kills all running RDS readers (frees the serial port).
#   2. Tunes the TEF chip to the requested frequency via serial.
#   3. Spawns tef-rds.pl for the new frequency.
#   4. If no hub is running: spawns tef-hub.pl (which starts ffmpeg and owns
#      the ALSA device).
#   5. Connects to the hub's Unix socket and relays the MP3 stream to stdout.
#
# Multiple players:
#   The hub is a single shared process — not tied to any particular frequency.
#   ffmpeg just reads whatever audio the tuner chip is currently outputting.
#   When a new player tunes to a different frequency (step 2), the hardware
#   switches and ALL connected players immediately hear the new frequency.
#   "Last player to tune wins" — but any number of players can listen
#   simultaneously without competing for the ALSA device.
#
# LMS reads the MP3 stream from this process's stdout via the transcoder pipe.

use strict;
use warnings;
use POSIX          qw(_exit setsid);
use Fcntl          qw(O_RDWR O_NOCTTY);
use IO::Select;
use IO::Socket::UNIX;

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

# Locate helper scripts alongside this one
(my $script_dir = __FILE__) =~ s{[^/]+$}{};
$script_dir =~ s{/$}{} if $script_dir ne '/';
my $rds_script = "$script_dir/tef-rds.pl";
my $hub_script = "$script_dir/tef-hub.pl";

# Prefer bundled static ffmpeg binary
my $ffmpeg = do {
    my $bundled = "$script_dir/ffmpeg";
    (-x $bundled) ? $bundled : 'ffmpeg';
};

# Single shared hub socket — not frequency-specific, because ffmpeg just reads
# whatever audio the tuner chip outputs; retuning the chip is enough.
my $hub_sock    = '/tmp/tefradio-hub.sock';
my $hub_pidfile = "$hub_sock.pid";
my $rds_pidfile = "/tmp/tefradio-rds-${freq_khz}.json.pid";
my $rds_json    = "/tmp/tefradio-rds-${freq_khz}.json";

# ── 1. Kill all running RDS readers (free the serial port) ────────────────
for my $pf (glob('/tmp/tefradio-rds-*.json.pid')) {
    _kill_pidfile($pf);
}

# ── 2. Tune hardware ──────────────────────────────────────────────────────
_tune($port, $freq_khz);

# Hardware needs a moment to switch frequency cleanly
select(undef, undef, undef, 0.35);

# ── 3. Spawn RDS reader for the new frequency ─────────────────────────────
if (-f $rds_script) {
    _spawn_rds($rds_script, $port, $freq_khz, $rds_json, $rds_pidfile);
}

# ── 4. Ensure hub is running ───────────────────────────────────────────────
# If a hub is already running (another player is listening), we simply
# connect to it — no need to touch ffmpeg, which is already streaming.
# If not running, start it now.
my $hub_client = _try_connect($hub_sock);

unless ($hub_client) {
    _kill_pidfile($hub_pidfile) if -f $hub_pidfile;   # clean up stale PID

    _spawn_hub($hub_script, $alsa_dev, $bitrate, $hub_sock, $ffmpeg);

    # Wait up to 5 s for the hub to create its socket and start listening
    my $deadline = time() + 5;
    until ($hub_client || time() > $deadline) {
        $hub_client = _try_connect($hub_sock);
        select(undef, undef, undef, 0.05) unless $hub_client;
    }

    die "tef-stream: hub failed to start (ALSA device unavailable?)\n"
        unless $hub_client;
}

# ── 5. Relay hub's MP3 stream → stdout (which LMS reads) ──────────────────
_relay($hub_client);


# ── Subroutines ───────────────────────────────────────────────────────────

# Try to connect to the hub socket.
# Returns IO::Socket::UNIX on success, undef if socket absent or refused.
sub _try_connect {
    my ($sock_path) = @_;
    return undef unless -S $sock_path;
    return IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $sock_path);
}

# Copy data from $sock → STDOUT until either end closes.
sub _relay {
    my ($sock) = @_;
    while (1) {
        my $n = sysread($sock, my $buf, 65536);
        last unless defined $n && $n > 0;   # hub closed or EOF
        my $off = 0;
        while ($off < length($buf)) {
            my $w = syswrite(STDOUT, $buf, length($buf) - $off, $off);
            last unless defined $w;          # LMS closed the pipe
            $off += $w;
        }
    }
    close $sock;
}

# Kill a process whose PID is stored in $pidfile, then remove the file.
sub _kill_pidfile {
    my ($pidfile) = @_;
    return unless -f $pidfile;
    if (open my $fh, '<', $pidfile) {
        my $pid = <$fh>; chomp $pid; close $fh;
        kill('TERM', $pid) if $pid =~ /^\d+$/;
    }
    unlink $pidfile;
}

# Double-fork the hub so it is fully detached from this transcoder process.
sub _spawn_hub {
    my ($script, $alsa_dev, $bitrate, $sock_path, $ffmpeg_bin) = @_;

    my $pid = fork();
    return unless defined $pid;

    if ($pid == 0) {
        my $gc = fork();
        _exit(defined $gc ? 0 : 1) if !defined $gc || $gc != 0;

        setsid();
        open(STDIN,  '<',  '/dev/null');
        open(STDOUT, '>',  '/dev/null');
        open(STDERR, '>>', '/tmp/tefradio-hub.log');

        exec($^X, $script, $alsa_dev, $bitrate, $sock_path, $ffmpeg_bin)
            or _exit(1);
    }

    waitpid($pid, 0);
}

# Double-fork the RDS reader so it is fully detached from this process.
sub _spawn_rds {
    my ($script, $port, $freq_khz, $json_file, $pidfile) = @_;

    my $pid = fork();
    return unless defined $pid;

    if ($pid == 0) {
        my $gc = fork();
        _exit(defined $gc ? 0 : 1) if !defined $gc || $gc != 0;

        setsid();
        open(STDIN,  '<',  '/dev/null');
        open(STDOUT, '>',  '/dev/null');
        open(STDERR, '>>', '/tmp/tefradio-rds.log');
        exec($^X, $script, $port, $freq_khz, $json_file)
            or _exit(1);
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
