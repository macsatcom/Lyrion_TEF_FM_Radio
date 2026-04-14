#!/usr/bin/env perl
# tef-hub.pl — MP3 broadcast hub for TEF Radio
#
# Usage: tef-hub.pl <freq_khz> <alsa_dev> <bitrate> <sock_path> <ffmpeg>
#
# Creates a Unix domain socket at <sock_path>, starts ffmpeg reading from
# <alsa_dev>, and broadcasts the MP3 stream to all connected clients.
#
# Design:
#   - Socket is created BEFORE ffmpeg starts, so clients can connect
#     immediately while ffmpeg is initialising.
#   - Each MP3 chunk from ffmpeg is sent to every client in one non-blocking
#     syswrite.  A slow or paused client whose kernel buffer is full gets
#     dropped (radio: if you can't keep up, you're out).
#   - Exits NO_CLIENT_TIMEOUT seconds after the last client disconnects, or
#     immediately when ffmpeg exits.
#
# PID is written to <sock_path>.pid on startup so tef-stream.pl can kill us.

use strict;
use warnings;
use POSIX         qw(_exit);
use IO::Select;
use IO::Socket::UNIX;

sub _log { warn scalar(localtime) . ": tef-hub: @_\n" }

unless (@ARGV == 4) {
    print STDERR "Usage: tef-hub.pl <alsa_dev> <bitrate> <sock_path> <ffmpeg>\n";
    exit 1;
}

my ($alsa_dev, $bitrate, $sock_path, $ffmpeg) = @ARGV;
my $pid_file         = "$sock_path.pid";
my $NO_CLIENT_TIMEOUT = 5;   # seconds to wait after last client before exiting

# Write our PID so tef-stream.pl can kill us if needed
if (open my $pf, '>', $pid_file) { print $pf $$; close $pf }

# Remove stale socket from a previous (crashed) run
unlink $sock_path if -e $sock_path;

# Create server socket BEFORE starting ffmpeg so clients can queue up
my $server = IO::Socket::UNIX->new(
    Type   => SOCK_STREAM,
    Local  => $sock_path,
    Listen => 16,
) or do { _log("cannot create socket $sock_path: $!"); exit 1 };
$server->blocking(0);

_log("pid=$$  dev=$alsa_dev  sock=$sock_path");

# ── Start ffmpeg as child, capture its stdout via a pipe ──────────────────
pipe(my $ff_rd, my $ff_wr) or do { _log("pipe: $!"); exit 1 };

my $ffmpeg_pid = fork();
die "fork: $!" unless defined $ffmpeg_pid;

if ($ffmpeg_pid == 0) {   # child
    close $ff_rd;
    open(STDOUT, '>&', $ff_wr) or _exit(1);
    open(STDIN,  '<',  '/dev/null');
    open(STDERR, '>>', '/tmp/tefradio-hub.log');
    exec(
        $ffmpeg,
        '-loglevel', 'error',
        '-f',        'alsa',
        '-i',        $alsa_dev,
        '-c:a',      'libmp3lame',
        '-b:a',      $bitrate,
        '-f',        'mp3',
        'pipe:1',
    ) or _exit(1);
}
close $ff_wr;
_log("ffmpeg pid=$ffmpeg_pid");

# ── Broadcast loop ─────────────────────────────────────────────────────────
my $sel        = IO::Select->new($server, $ff_rd);
my %clients;           # fileno(fh) => fh
my $ff_done    = 0;    # 1=ffmpeg EOF, 2=SIGTERM received
my $empty_since = time();

local $SIG{TERM} = sub { $ff_done = 2 };
local $SIG{CHLD} = 'IGNORE';

LOOP: while (1) {
    # No-client timeout: give up waiting, kill ffmpeg, exit
    if (!%clients && time() - $empty_since >= $NO_CLIENT_TIMEOUT) {
        _log("no clients for ${NO_CLIENT_TIMEOUT}s — stopping");
        last;
    }
    last if $ff_done >= 2;

    my @ready = $sel->can_read(1.0);

    for my $fh (@ready) {

        # ── New client connecting ──────────────────────────────────────────
        if (fileno($fh) == fileno($server)) {
            my $client = $server->accept or next;
            $client->blocking(0);
            $clients{fileno($client)} = $client;
            _log("client connected  fd=" . fileno($client)
                 . "  total=" . scalar(keys %clients));
        }

        # ── Data from ffmpeg ───────────────────────────────────────────────
        elsif (!$ff_done && fileno($fh) == fileno($ff_rd)) {
            my $n = sysread($ff_rd, my $chunk, 65536);
            if (!defined($n) || $n == 0) {
                _log("ffmpeg stdout EOF");
                $ff_done = 1;
                $sel->remove($ff_rd);
                last LOOP;
            }
            _broadcast(\%clients, $chunk);
            $empty_since = time() if %clients;
        }
    }

    # Keep empty_since fresh while there are no clients
    $empty_since = time() unless %clients;
}

# ── Shutdown ───────────────────────────────────────────────────────────────
_log("shutting down");
kill('TERM', $ffmpeg_pid) if $ffmpeg_pid && !$ff_done;
waitpid($ffmpeg_pid, 0)   if $ffmpeg_pid;

close $_ for values %clients;
close $server;
unlink $sock_path;
unlink $pid_file;
_log("done");


# ── Subroutines ────────────────────────────────────────────────────────────

# Broadcast $chunk to every client.  Any client that returns an error or
# accepts fewer bytes than offered (kernel buffer full = too slow) is dropped.
# This is intentional: live radio does not buffer for slow listeners.
sub _broadcast {
    my ($clients, $chunk) = @_;
    my @dead;
    for my $fn (keys %$clients) {
        my $w = syswrite($clients->{$fn}, $chunk);
        push @dead, $fn if !defined($w) || $w < length($chunk);
    }
    for my $fn (@dead) {
        close delete $clients->{$fn};
        _log("client dropped  fd=$fn  remaining=" . scalar(keys %$clients));
    }
}
