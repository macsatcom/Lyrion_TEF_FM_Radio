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
use Fcntl   qw(O_RDONLY O_NOCTTY);
use IO::Select;
use POSIX   ();
use JSON::PP;

unless (@ARGV == 3) {
    print STDERR "Usage: tef-rds.pl <serial_port> <freq_khz> <output_json>\n";
    exit 1;
}

my ($port, $freq_khz, $out_file) = @ARGV;
my $pid_file = "$out_file.pid";

# Write PID file so the plugin can kill us
open(my $pf, '>', $pid_file) and do { print $pf $$; close $pf };

my $running = 1;
$SIG{TERM} = sub { $running = 0 };
$SIG{INT}  = sub { $running = 0 };

# Wait briefly for tef-stream.pl to finish tuning and close the serial port
select(undef, undef, undef, 0.7);

# Configure and open serial port (read-only — we never send commands)
system('stty', '-F', $port, qw(115200 cs8 -cstopb -parenb raw -echo));
unless (sysopen(my $tty, $port, O_RDONLY | O_NOCTTY)) {
    warn "tef-rds: cannot open $port: $!\n";
    unlink $pid_file;
    exit 1;
}

my $sel = IO::Select->new($tty);
my $buf = '';

# ── RDS state ─────────────────────────────────────────────────────────────────
my @ps       = (' ') x 8;   # 8-char Programme Service name
my @rt       = (' ') x 64;  # 64-char RadioText (2A groups)
my $rt_ab    = -1;           # A/B flip-flop — detects new RT message
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

        my ($B, $C, $D) = (hex($1), hex($2), hex($3));
        # err hex($4) — we ignore error flags for now

        my $group_type = ($B >> 12) & 0xF;
        my $version    = ($B >> 11) & 0x1;   # 0 = variant A, 1 = variant B

        my $changed = 0;

        # ── Group 0 (0A/0B): Programme Service name ────────────────────────
        if ($group_type == 0) {
            my $seg = $B & 0x3;       # 2-bit segment address → position in PS
            my $c1  = ($D >> 8) & 0xFF;
            my $c2  =  $D       & 0xFF;
            # Only store printable ASCII (stations sometimes pad with 0x20 or 0x0D)
            my $new1 = ($c1 >= 0x20 && $c1 < 0x7F) ? chr($c1) : ' ';
            my $new2 = ($c2 >= 0x20 && $c2 < 0x7F) ? chr($c2) : ' ';
            if ($ps[$seg * 2] ne $new1 || $ps[$seg * 2 + 1] ne $new2) {
                $ps[$seg * 2]     = $new1;
                $ps[$seg * 2 + 1] = $new2;
                $changed = 1;
            }
        }

        # ── Group 2A: RadioText ────────────────────────────────────────────
        elsif ($group_type == 2 && $version == 0) {
            my $ab  = ($B >> 4) & 0x1;   # A/B flag
            my $seg =  $B       & 0xF;   # 4-bit segment → position in RT

            # A/B toggle signals a new RT message; clear the buffer
            if ($rt_ab != -1 && $ab != $rt_ab) {
                @rt = (' ') x 64;
                $changed = 1;
            }
            $rt_ab = $ab;

            # Group 2A carries 4 chars: C_hi C_lo D_hi D_lo
            my @chars = (($C >> 8) & 0xFF, $C & 0xFF, ($D >> 8) & 0xFF, $D & 0xFF);
            for my $i (0 .. 3) {
                my $c = $chars[$i];
                if ($c == 0x0D) {
                    # Carriage return = end-of-message; pad remainder with spaces
                    $rt[$_] = ' ' for ($seg * 4 + $i .. 63);
                    $changed = 1;
                    last;
                }
                my $new = ($c >= 0x20 && $c < 0x7F) ? chr($c) : ' ';
                if ($rt[$seg * 4 + $i] ne $new) {
                    $rt[$seg * 4 + $i] = $new;
                    $changed = 1;
                }
            }
        }

        if ($changed) {
            my $ps_str = join('', @ps);
            my $rt_str = join('', @rt);
            $rt_str =~ s/\s+$//;   # trim trailing whitespace

            $data{ps}      = $ps_str;
            $data{rt}      = $rt_str;
            $data{updated} = time();
            _write_json($out_file, \%data);
        }
    }
}

close($tty);
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
