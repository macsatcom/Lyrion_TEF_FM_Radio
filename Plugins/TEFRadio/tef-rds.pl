#!/usr/bin/env perl
# tef-rds.pl — Background RDS reader for the TEF FM Radio Lyrion plugin
# -----------------------------------------------------------------------
# Usage:
#   perl tef-rds.pl <serial_port> <freq_khz> <output_json>
#
# Runs as a background daemon alongside ffmpeg (which reads ALSA audio).
# ffmpeg never touches the serial port, so this process can own it freely.
#
# What it parses:
#   P<XXXX>   — PI code (station identifier)
#   R<B><C><D><err>  — RDS group (legacy format, default firmware setting)
#     Group 0: PS name (Programme Service, 8 chars)
#     Group 2A: RadioText (up to 64 chars)
#     Group 4A: Clock-Time (ignored)
#
# Output JSON written to <output_json> on every change:
#   { "ps": "DR P1   ", "rt": "Now: Morning Show", "pi": "3201",
#     "freq_khz": 90800, "updated": 1712345678 }
#
# Writes its PID to <output_json>.pid on startup so the plugin can kill it.
# Removes both files on clean exit.

use strict;
use warnings;
use utf8;
use Fcntl   qw(O_RDONLY O_NOCTTY :flock);
use IO::Select;
use POSIX   ();
use JSON::PP;

# Log to stderr (which _spawn_rds redirects to /tmp/tefradio-rds.log)
sub _log { warn scalar(localtime) . ": tef-rds: @_\n" }

unless (@ARGV == 3) {
    print STDERR "Usage: tef-rds.pl <serial_port> <freq_khz> <output_json>\n";
    exit 1;
}

my ($port, $freq_khz, $out_file) = @ARGV;
my $pid_file = "$out_file.pid";

_log("starting pid=$$ port=$port freq=${freq_khz}kHz");

# ── Single-instance lock ──────────────────────────────────────────────────────
# Only ONE process may read the serial port.  If two readers run at once,
# each gets random fragments of every line and RDS text turns into garbage.
# A previous reader still holding the lock is terminated.
my $lock_file = '/tmp/tefradio-rds.lock';
open(my $lock_fh, '+>>', $lock_file) or die "tef-rds: cannot open $lock_file: $!\n";
unless (flock($lock_fh, LOCK_EX | LOCK_NB)) {
    seek($lock_fh, 0, 0);
    my $old = <$lock_fh>;
    if (defined $old && $old =~ /^(\d+)/ && $1 != $$) {
        _log("another reader (pid $1) holds the port, terminating it");
        kill('TERM', $1);
    }
    my $deadline = time() + 3;
    until (flock($lock_fh, LOCK_EX | LOCK_NB)) {
        if (time() > $deadline) {
            _log("could not acquire $lock_file, exiting");
            exit 1;
        }
        select(undef, undef, undef, 0.1);
    }
}
truncate($lock_fh, 0);
syswrite($lock_fh, "$$\n");

# Write PID file so the plugin can kill us
if (open my $pf, '>', $pid_file) { print $pf $$; close $pf }

my $running        = 1;
my $log_lines      = 0;   # log first few raw lines to show what tuner outputs
my $log_first_json = 1;   # log once when we successfully write RDS data
my $last_heartbeat = 0;   # time of last periodic JSON refresh
$SIG{TERM} = sub { $running = 0 };
$SIG{INT}  = sub { $running = 0 };

# Wait briefly for tef-stream.pl to finish tuning and close the serial port
select(undef, undef, undef, 0.7);

# Configure and open serial port (read-only — we never send commands)
_log("opening $port read-only");
system('stty', '-F', $port, qw(115200 cs8 -cstopb -parenb raw -echo));
my $tty;
unless (sysopen($tty, $port, O_RDONLY | O_NOCTTY)) {
    _log("FAILED to open $port: $!");
    unlink $pid_file;
    exit 1;
}
_log("port open OK, reading RDS data");

my $sel = IO::Select->new($tty);
my $buf = '';

# ── RDS character set (EN 50067 / IEC 62106 Annex E, "G0" table) ─────────────
# RDS does NOT use Latin-1.  Danish letters are æ=0xF2 ø=0xF7 å=0xF1,
# Æ=0xE2 Ø=0xE7 Å=0xE1.  Index = byte - 0x20.
my @EBU = split //,
    ' !"#¤%&\'()*+,-./0123456789:;<=>?' .
    '@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]―_' .
    '‖abcdefghijklmnopqrstuvwxyz{|}¯ ' .
    'áàéèíìóòúùÑÇŞß¡Ĳ' .
    'âäêëîïôöûüñçşğıĳ' .
    'ªα©‰Ğěňőπ€£$←↑→↓' .
    'º¹²³±İńűµ¿÷°¼½¾§' .
    'ÁÀÉÈÍÌÓÒÚÙŘČŠŽÐĿ' .
    'ÂÄÊËÎÏÔÖÛÜřčšžđŀ' .
    'ÃÅÆŒŷÝÕØÞŊŔĆŚŹŦð' .
    'ãåæœŵýõøþŋŕćśźŧ ';
die "EBU table size wrong: " . scalar(@EBU) unless @EBU == 224;

sub _ebu { my $c = shift; return $c >= 0x20 ? $EBU[$c - 0x20] : ' ' }

# Max accepted error level per block (0 = none, 1 = 1-2 bits corrected,
# 2 = 3-5 bits corrected, 3 = uncorrectable).  Strict, like librdsparser.
my $MAX_ERR = 0;

# ── RDS state ─────────────────────────────────────────────────────────────────
my @ps       = (' ') x 8;   # 8-char Programme Service name
my @rt       = (' ') x 64;  # 64-char RadioText (2A groups)
my $rt_ab    = -1;           # A/B flip-flop — detects new RT message
my %rt_seen;                 # segments received for the current RT message
my $rt_end   = 64;           # message length (set when 0x0D end marker seen)
my $rt_done  = '';           # last COMPLETE RadioText — what we publish
my $pi       = '';

my %data = (
    ps       => '',
    rt       => '',
    pi       => '',
    freq_khz => int($freq_khz),
    updated  => 0,
);

# ── Main read loop ─────────────────────────────────────────────────────────────
while ($running) {
    # Heartbeat: refresh JSON timestamp every 20 s even when RDS is stable.
    # This prevents ProtocolHandler.pm from treating the file as stale when
    # the station's PS/RT hasn't changed (and tef-rds.pl therefore hasn't
    # written any new data for a while).
    if (time() - $last_heartbeat >= 20) {
        $last_heartbeat = time();
        $data{updated}  = time();
        _write_json($out_file, \%data);
    }

    my @ready = $sel->can_read(0.5);
    unless (@ready) {
        # If the port has vanished (USB unplugged), exit
        last unless -e $port;
        next;
    }

    my $n = sysread($tty, my $chunk, 512);
    last unless defined $n && $n > 0;

    $buf .= $chunk;

    # Process complete lines
    while ($buf =~ s/^([^\n]*)\n//) {
        my $line = $1;
        $line =~ s/\r//g;
        next unless length $line;

        # Log the first 5 lines so we can see what the tuner is outputting
        if ($log_lines < 5) {
            _log("tuner line: $line");
            $log_lines++;
        }

        # PI code: P<4hex>[?*]
        if ($line =~ /^P([0-9A-Fa-f]{4})\??/) {
            my $new_pi = uc($1);
            if ($new_pi ne $pi) {
                $pi = $new_pi;
                $data{pi}      = $pi;
                $data{updated} = time();
                _write_json($out_file, \%data);
            }
            next;
        }

        # RDS group (legacy format): R<B:4hex><C:4hex><D:4hex><err:2hex>
        next unless $line =~ /^R([0-9A-Fa-f]{4})([0-9A-Fa-f]{4})([0-9A-Fa-f]{4})([0-9A-Fa-f]{2})$/;

        my ($B, $C, $D, $err) = (hex($1), hex($2), hex($3), hex($4));
        # Error byte: 2 bits per block, A=bits 7-6, B=5-4, C=3-2, D=1-0
        # (legacy format has no block A, but the flags keep the same layout).
        my ($eB, $eC, $eD) = (($err >> 4) & 3, ($err >> 2) & 3, $err & 3);
        next if $eB > $MAX_ERR;   # group type/address unreliable

        my $group_type = ($B >> 12) & 0xF;
        my $version    = ($B >> 11) & 0x1;   # 0 = variant A, 1 = variant B

        my $changed = 0;

        # ── Group 0 (0A/0B): Programme Service name ────────────────────────
        if ($group_type == 0) {
            next if $eD > $MAX_ERR;
            my $seg  = $B & 0x3;
            my $new1 = _ebu(($D >> 8) & 0xFF);
            my $new2 = _ebu( $D       & 0xFF);
            if ($ps[$seg * 2] ne $new1 || $ps[$seg * 2 + 1] ne $new2) {
                $ps[$seg * 2]     = $new1;
                $ps[$seg * 2 + 1] = $new2;
                $changed = 1;
            }
        }

        # ── Group 2A / 2B: RadioText ───────────────────────────────────────
        elsif ($group_type == 2) {
            my $ab  = ($B >> 4) & 0x1;
            my $seg =  $B       & 0xF;

            # 2A: 4 chars in C+D (64-char text).  2B: 2 chars in D (32-char).
            my @bytes;
            if ($version == 0) {
                next if $eC > $MAX_ERR || $eD > $MAX_ERR;
                @bytes = (($C >> 8) & 0xFF, $C & 0xFF, ($D >> 8) & 0xFF, $D & 0xFF);
            } else {
                next if $eD > $MAX_ERR;
                @bytes = (($D >> 8) & 0xFF, $D & 0xFF);
            }
            my $width = scalar @bytes;

            # A/B toggle = new message: start collecting from scratch
            if ($ab != $rt_ab) {
                @rt = (' ') x 64;
                %rt_seen = ();
                $rt_end  = $version == 0 ? 64 : 32;
                $rt_ab   = $ab;
            }

            for my $i (0 .. $#bytes) {
                my $pos = $seg * $width + $i;
                if ($bytes[$i] == 0x0D) { $rt_end = $pos; last }
                $rt[$pos] = _ebu($bytes[$i]);
            }
            $rt_seen{$seg} = 1;

            # Publish only once every segment of the message has arrived,
            # so listeners never see half-received text.
            my $needed = int(($rt_end + $width - 1) / $width);
            if (!grep { !$rt_seen{$_} } 0 .. $needed - 1) {
                (my $txt = join('', @rt[0 .. $rt_end - 1])) =~ s/\s+$//;
                $txt =~ s/^\s+//;
                if ($txt ne $rt_done) {
                    $rt_done = $txt;
                    $changed = 1;
                }
            }
        }

        if ($changed) {
            my $ps_str = join('', @ps);
            my $rt_str = $rt_done;

            $data{ps}      = $ps_str;
            $data{rt}      = $rt_str;
            $data{updated} = time();
            _write_json($out_file, \%data);
            if ($log_first_json) {
                _log("first JSON write: ps='$ps_str' rt='$rt_str'");
                $log_first_json = 0;
            }
        }
    }
}

close($tty);
truncate($lock_fh, 0);
close($lock_fh);   # releases the flock
unlink $out_file;
unlink $pid_file;


sub _write_json {
    my ($file, $data) = @_;
    my $tmp = "$file.tmp";
    if (open my $fh, '>', $tmp) {
        print $fh JSON::PP->new->utf8->encode($data);
        close $fh;
        rename $tmp, $file;
    }
}
