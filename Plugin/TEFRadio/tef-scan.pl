#!/usr/bin/env perl
# tef-scan.pl — FM band scanner for the TEF668X tuner
# -----------------------------------------------------
# Usage:
#   perl tef-scan.pl <serial_port> [rssi_threshold_dbf]
#
# Scans 87.5–108 MHz in 100 kHz steps and prints a JSON array of found
# stations to stdout. Stations below the RSSI threshold are excluded.
#
# Output format:
#   [ { "freq_khz": 90800, "freq_mhz": 90.8, "rssi": 18.5, "name": "FM 90.8 MHz" }, ... ]
#
# Stations are sorted by signal strength (strongest first).
# Call with --deep to also resolve PS names from RDS (slower: ~5s per station).

use strict;
use warnings;
use Fcntl   qw(O_RDWR O_NOCTTY);
use IO::Select;
use POSIX   ();
use JSON::PP;

my $port      = shift // '/dev/ttyACM0';
my $threshold = (@ARGV && $ARGV[0] =~ /^[\d.]+$/) ? shift : 5;   # dBf
my $deep      = grep { $_ eq '--deep' } @ARGV;

# ── Kill any running RDS readers to free the serial port ─────────────────────
for my $pf (glob('/tmp/tefradio-rds-*.json.pid')) {
    if (open my $fh, '<', $pf) {
        my $pid = <$fh>; chomp $pid;
        close $fh;
        kill('TERM', $pid) if $pid =~ /^\d+$/;
    }
    unlink $pf;
}
select(undef, undef, undef, 0.4);   # 400 ms for port to be released

# ── Open serial port ──────────────────────────────────────────────────────────
system('stty', '-F', $port, qw(115200 cs8 -cstopb -parenb raw -echo));
unless (sysopen(my $tty, $port, O_RDWR | O_NOCTTY)) {
    warn "tef-scan: cannot open $port: $!\n";
    print "[]\n";
    exit 1;
}

my $sel = IO::Select->new($tty);

# ── Startup handshake ─────────────────────────────────────────────────────────
_send($tty, 'x');
unless (_wait_for($sel, qr/^OK$/, 4)) {
    warn "tef-scan: no OK from tuner\n";
    print "[]\n";
    close $tty;
    exit 1;
}

# ── FM band scan: 87.5–108 MHz, 100 kHz steps ────────────────────────────────
_send($tty, 'Sa87500');
_send($tty, 'Sb108000');
_send($tty, 'Sc100');
_send($tty, 'S');

# Scan takes ~5–15 seconds depending on firmware; wait up to 60 s
my $result_line = _wait_for($sel, qr/^U/, 60);

my @stations;

if ($result_line && $result_line =~ /^U(.+)$/) {
    for my $entry (split /,/, $1) {
        next unless $entry =~ /^(\d+)=([-\d.]+)$/;
        my ($khz, $rssi) = (int($1), $2 + 0);
        next if $rssi < $threshold;
        push @stations, {
            freq_khz => $khz,
            freq_mhz => $khz / 1000,
            rssi     => $rssi,
            name     => sprintf('FM %.1f MHz', $khz / 1000),
        };
    }
    @stations = sort { $b->{rssi} <=> $a->{rssi} } @stations;
}

# ── Deep scan: tune each found station and wait for RDS PS name ───────────────
if ($deep && @stations) {
    for my $s (@stations) {
        _send($tty, "T$s->{freq_khz}");
        _wait_for($sel, qr/^T\d+/, 2);   # wait for tune confirmation

        # Collect RDS lines for up to 8 seconds; stop as soon as PS is complete
        my @ps   = (' ') x 8;
        my $deadline = time() + 8;
        while (time() < $deadline) {
            my $line = _readline($sel, $deadline - time());
            last unless defined $line;

            if ($line =~ /^R([0-9A-Fa-f]{4})([0-9A-Fa-f]{4})([0-9A-Fa-f]{4})[0-9A-Fa-f]{2}$/) {
                my ($B, undef, $D) = (hex($1), hex($2), hex($3));
                my $group_type = ($B >> 12) & 0xF;
                if ($group_type == 0) {
                    my $seg = $B & 0x3;
                    $ps[$seg * 2]     = _rds_char(($D >> 8) & 0xFF);
                    $ps[$seg * 2 + 1] = _rds_char($D & 0xFF);
                    if ($seg == 3) {
                        # Got all 4 segments — PS name complete
                        my $name = join('', @ps);
                        $name =~ s/\s+$//;
                        $s->{name} = $name if $name =~ /\S/;
                        last;
                    }
                }
            }
        }
    }
}

close($tty);
print JSON::PP->new->encode(\@stations), "\n";


# ── Helpers ───────────────────────────────────────────────────────────────────

sub _send {
    my ($fh, $cmd) = @_;
    syswrite($fh, "$cmd\n");
}

sub _readline {
    my ($sel, $timeout) = @_;
    $timeout = 0.5 if $timeout <= 0;
    state $buf = '';
    my $dead = time() + $timeout;
    while (time() < $dead) {
        if ($buf =~ s/^([^\n]*)\n//) {
            my $line = $1;
            $line =~ s/\r//g;
            return $line;
        }
        my $left  = $dead - time();
        my @ready = $sel->can_read($left < 0.2 ? $left : 0.2);
        next unless @ready;
        my $n = sysread(($sel->handles)[0], my $chunk, 512);
        next unless defined $n && $n > 0;
        $buf .= $chunk;
    }
    return undef;
}

sub _wait_for {
    my ($sel, $pattern, $timeout) = @_;
    my $dead = time() + $timeout;
    while (time() < $dead) {
        my $line = _readline($sel, $dead - time());
        return $line if defined $line && $line =~ $pattern;
    }
    return undef;
}

sub _rds_char {
    my ($c) = @_;
    return ($c >= 0x20 && $c < 0x7F) ? chr($c) : ' ';
}
