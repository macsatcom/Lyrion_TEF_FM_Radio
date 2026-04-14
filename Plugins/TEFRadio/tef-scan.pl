#!/usr/bin/env perl
# tef-scan.pl — FM band scanner for the TEF668X tuner
# -----------------------------------------------------
# Usage:
#   perl tef-scan.pl <serial_port> [rssi_threshold_dbf]
#
# Scans 87.5–108 MHz in 100 kHz steps, measures CCI (co-channel interference),
# and reads RDS PS name for each surviving station.  Stations below the RSSI
# threshold or with CCI above the limit are excluded.
#
# Output format:
#   [ { "freq_khz": 90800, "freq_mhz": 90.8, "rssi": 18.5, "cci": 12, "name": "DR P1" }, ... ]
#
# Stations are sorted by frequency (ascending).

use strict;
use warnings;
use Fcntl   qw(O_RDWR O_NOCTTY);
use IO::Select;
use POSIX   ();
use JSON::PP;

my $LOGFILE = '/tmp/tefradio-scan.log';
sub _log {
    if (open my $f, '>>', $LOGFILE) {
        print $f scalar(localtime) . ": @_\n";
        close $f;
    }
    warn "@_\n";   # also goes to LMS log via stderr
}

my $port      = shift // '/dev/ttyACM0';
my $threshold = (@ARGV && $ARGV[0] =~ /^[\d.]+$/) ? shift : 10;  # dBf
my $cci_max   = 35;   # drop stations with CCI above this

_log("tef-scan starting: port=$port threshold=$threshold cci_max=$cci_max");

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
_log("opening port $port");
system('stty', '-F', $port, qw(115200 cs8 -cstopb -parenb raw -echo));
my $tty;
unless (sysopen($tty, $port, O_RDWR | O_NOCTTY)) {
    _log("FAILED to open $port: $!");
    print "[]\n";
    exit 1;
}
_log("port opened OK");

my $sel = IO::Select->new($tty);

# ── Startup handshake ─────────────────────────────────────────────────────────
_log("sending init 'x', waiting for OK");
_send($tty, 'x');
unless (_wait_for($sel, qr/^OK$/, 4)) {
    _log("no OK from tuner within 4s");
    print "[]\n";
    close $tty;
    exit 1;
}
_log("got OK from tuner");

# ── FM band scan: 87.5–108 MHz, 100 kHz steps ────────────────────────────────
_log("sending scan commands Sa/Sb/Sc/S");
_send($tty, 'Sa87500');
_send($tty, 'Sb108000');
_send($tty, 'Sc100');
_send($tty, 'S');

# Scan takes ~5–15 seconds depending on firmware; wait up to 60 s
_log("waiting up to 60s for scan result (U line)");
my $result_line = _wait_for($sel, qr/^U/, 60);
_log(defined $result_line ? "got result: " . substr($result_line, 0, 80) : "scan timed out — no U line received");

my @candidates;

if ($result_line && $result_line =~ /^U(.+)$/) {
    for my $entry (split /,/, $1) {
        next unless $entry =~ /^(\d+)=([-\d.]+)$/;
        my ($khz, $rssi) = (int($1), $2 + 0);
        next if $rssi < $threshold;
        push @candidates, {
            freq_khz => $khz,
            freq_mhz => $khz / 1000,
            rssi     => $rssi,
            name     => sprintf('FM %.1f MHz', $khz / 1000),
        };
    }
    @candidates = sort { $b->{rssi} <=> $a->{rssi} } @candidates;
    _log(sprintf("%d candidates above %s dBf threshold", scalar @candidates, $threshold));
}

# ── Per-station check: CCI quality filter + RDS PS name ──────────────────────
# Tune to each candidate, wait up to 5 s collecting:
#   S-lines  → RSSI and CCI (co-channel interference)
#   R-lines  → RDS group 0 → PS name (8 chars across 4 segments)
# Stations with avg CCI > cci_max are dropped.
# RDS PS name replaces the generic "FM x.x MHz" label when found.

my @stations;

for my $s (@candidates) {
    _log(sprintf("checking %.1f MHz (RSSI %.1f)", $s->{freq_mhz}, $s->{rssi}));
    _send($tty, "T$s->{freq_khz}");
    select(undef, undef, undef, 0.35);   # let tuner settle

    my (@cci_vals, @rssi_vals);
    my @ps_chars   = (' ') x 8;
    my $ps_segs    = 0;             # bitmask of received segments 0-3
    my $deadline   = time() + 5;   # 5 s window for CCI + RDS

    while (time() < $deadline) {
        # Early exit: have enough CCI samples AND complete PS
        last if @cci_vals >= 4 && $ps_segs == 0xF;

        my $line = _readline($sel, $deadline - time());
        next unless defined $line;

        if ($line =~ /^S(.)([-\d.]+),([-\d]+)/) {
            push @rssi_vals, $2 + 0;
            push @cci_vals,  $3 + 0;
        }
        elsif ($line =~ /^R([0-9A-Fa-f]{4})([0-9A-Fa-f]{4})([0-9A-Fa-f]{4})[0-9A-Fa-f]{2}$/) {
            my ($B, undef, $D) = (hex($1), hex($2), hex($3));
            if ((($B >> 12) & 0xF) == 0) {   # group type 0 = PS
                my $seg = $B & 0x3;
                $ps_chars[$seg * 2]     = _rds_char(($D >> 8) & 0xFF);
                $ps_chars[$seg * 2 + 1] = _rds_char($D & 0xFF);
                $ps_segs |= (1 << $seg);
            }
        }
    }

    # CCI filter
    if (@cci_vals) {
        my $avg_cci  = int(0.5 + _avg(@cci_vals));
        my $avg_rssi = _avg(@rssi_vals);
        $s->{cci}  = $avg_cci;
        $s->{rssi} = $avg_rssi;
        if ($avg_cci > $cci_max) {
            _log(sprintf("  → SKIP (CCI=%d > %d)", $avg_cci, $cci_max));
            next;
        }
        _log(sprintf("  → OK (RSSI=%.1f CCI=%d)", $avg_rssi, $avg_cci));
    } else {
        _log("  → no quality data, keeping");
    }

    # RDS PS name (use if we got at least 2 of 4 segments — partial is OK)
    if ($ps_segs) {
        my $ps_name = join('', @ps_chars);
        $ps_name =~ s/\s+$//;
        if ($ps_name =~ /\S/) {
            _log(sprintf("  → RDS PS: '%s' (segs=0x%X)", $ps_name, $ps_segs));
            $s->{name} = $ps_name;
        }
    }

    push @stations, $s;
}

# Sort by frequency ascending
@stations = sort { $a->{freq_khz} <=> $b->{freq_khz} } @stations;

_log(sprintf("scan done: %d stations", scalar @stations));
close($tty);
print JSON::PP->new->encode(\@stations), "\n";


# ── Helpers ───────────────────────────────────────────────────────────────────

my $readline_buf = '';   # persistent buffer across _readline calls

sub _send {
    my ($fh, $cmd) = @_;
    syswrite($fh, "$cmd\n");
}

sub _readline {
    my ($sel, $timeout) = @_;
    $timeout = 0.5 if $timeout <= 0;
    my $dead = time() + $timeout;
    while (time() < $dead) {
        if ($readline_buf =~ s/^([^\n]*)\n//) {
            my $line = $1;
            $line =~ s/\r//g;
            return $line;
        }
        my $left  = $dead - time();
        my @ready = $sel->can_read($left < 0.2 ? $left : 0.2);
        next unless @ready;
        my $n = sysread(($sel->handles)[0], my $chunk, 512);
        next unless defined $n && $n > 0;
        $readline_buf .= $chunk;
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

sub _avg {
    my $sum = 0; $sum += $_ for @_; return $sum / @_;
}
