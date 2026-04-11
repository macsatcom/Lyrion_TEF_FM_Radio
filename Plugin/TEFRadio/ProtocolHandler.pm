package Plugins::TEFRadio::ProtocolHandler;

# Protocol handler for tefradio:// URLs.
#
# When Lyrion plays e.g. tefradio://90.8 (FM) or tefradio://810 (AM):
#
#   1. new() — spawns tef-stream.pl as a child process:
#                  perl tef-stream.pl <port> <freq_khz> <alsa_dev> <bitrate>
#              tef-stream.pl does the startup handshake, tunes the TEF via
#              serial (then closes the port), and exec()s into ffmpeg.
#              ffmpeg reads ALSA audio and writes MP3 to stdout (→ LMS).
#
#   2. new() — also spawns tef-rds.pl as a background daemon:
#                  perl tef-rds.pl <port> <freq_khz> /tmp/tefradio-rds-<freq>.json
#              tef-rds.pl opens the serial port (now free, since ffmpeg uses
#              only ALSA) and reads RDS continuously, writing PS name and
#              RadioText to a JSON file.
#
#   3. getMetadataFor() — reads that JSON file and returns live RDS data
#              as the "now playing" title/artist shown in the LMS UI.
#
# URL frequency conventions:
#   tefradio://90.8    FM 90.8 MHz  (decimal → MHz)
#   tefradio://100     FM 100 MHz   (integer 65–108 → MHz)
#   tefradio://90800   FM 90.8 MHz  (integer ≥65000 → kHz)
#   tefradio://810     AM 810 kHz   (integer 144–30000 → kHz)

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use File::Spec::Functions qw(catfile);
use JSON::PP;
use POSIX ();

my $log   = logger('plugin.tefradio');
my $prefs = preferences('plugin.tefradio');

# PID of the currently running tef-rds.pl process (if any)
my $rds_pid     = undef;
my $rds_pidfile = undef;

# ─── Protocol capabilities ────────────────────────────────────────────────────

sub isRemote        { 1 }
sub canSeek         { 0 }
sub isRewindable    { 0 }
sub canDirectStream { 0 }
sub getFormatForURL { 'mp3' }
sub contentType     { 'mp3' }

# ─── Stream construction ──────────────────────────────────────────────────────

sub new {
    my ($class, $args) = @_;

    my $song = $args->{song};
    my $url  = $song->currentTrack()->url();

    my ($freq_str) = $url =~ m{^tefradio://(.+)$};
    unless (defined $freq_str && $freq_str =~ /^\d+\.?\d*$/) {
        $log->error("TEFRadio: malformed URL: $url");
        return undef;
    }

    my $freq_khz = _url_to_khz($freq_str);
    unless (defined $freq_khz) {
        $log->error("TEFRadio: frequency out of range: $freq_str");
        return undef;
    }

    my $port    = $prefs->get('serial_port')  // '/dev/ttyACM0';
    my $device  = $prefs->get('audio_device') // 'hw:CARD=Tuner,DEV=0';
    my $bitrate = $prefs->get('bitrate')       // '192k';
    my $dir     = _plugin_dir();
    my $stream_script = catfile($dir, 'tef-stream.pl');
    my $rds_script    = catfile($dir, 'tef-rds.pl');

    unless (-f $stream_script) {
        $log->error("TEFRadio: tef-stream.pl not found at $stream_script");
        return undef;
    }

    $log->info(sprintf(
        "TEFRadio: starting stream — %s, port=%s, device=%s",
        _khz_label($freq_khz), $port, $device
    ));

    # ── Spawn audio stream (tef-stream.pl → ffmpeg → stdout pipe → LMS) ──────
    open(my $fh, '-|', $^X, $stream_script, $port, $freq_khz, $device, $bitrate)
        or do {
            $log->error("TEFRadio: cannot spawn tef-stream.pl: $!");
            return undef;
        };

    # ── Spawn RDS background reader ───────────────────────────────────────────
    # tef-stream.pl closes the serial port before exec()ing ffmpeg, so
    # tef-rds.pl can open it ~0.7s later without conflict.
    _spawn_rds_reader($rds_script, $port, $freq_khz) if -f $rds_script;

    bless $fh, $class;
    return $fh;
}

sub _spawn_rds_reader {
    my ($script, $port, $freq_khz) = @_;

    # Kill any previously running RDS reader
    _kill_rds_reader();

    my $json_file = "/tmp/tefradio-rds-${freq_khz}.json";
    $rds_pidfile  = "$json_file.pid";

    # Fork a child that immediately daemonises and exec()s tef-rds.pl.
    # We use double-fork so the grandchild is re-parented to init (PID 1),
    # keeping LMS's process table clean.
    my $pid = fork();
    if (!defined $pid) {
        $log->warn("TEFRadio: fork failed for RDS reader: $!");
        return;
    }

    if ($pid == 0) {
        # ── First child: fork again, then exit ──
        my $gc = fork();
        if (!defined $gc) { exit 1; }
        if ($gc != 0)     { exit 0; }   # first child exits — grandchild lives on

        # ── Grandchild: become session leader, redirect fds, exec ──
        POSIX::setsid();
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec($^X, $script, $port, $freq_khz, $json_file);
        exit 1;
    }

    # Parent: reap the first child immediately (grandchild is now orphan → init)
    waitpid($pid, 0);

    $log->info("TEFRadio: RDS reader started for ${\_khz_label($freq_khz)}, json=$json_file");
}

sub _kill_rds_reader {
    return unless defined $rds_pidfile && -f $rds_pidfile;
    if (open my $fh, '<', $rds_pidfile) {
        my $old_pid = <$fh>; chomp $old_pid;
        close $fh;
        if ($old_pid =~ /^\d+$/) {
            kill('TERM', $old_pid);
            $log->info("TEFRadio: sent SIGTERM to RDS reader PID $old_pid");
        }
    }
    $rds_pidfile = undef;
}

# ─── IO wrappers (LMS calls these on the blessed filehandle) ─────────────────

sub opened {
    my $self = shift;
    return defined CORE::fileno($self);
}

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
    my $freq_label = defined $freq_khz ? _khz_label($freq_khz)  : 'Radio';

    # ── Try to find a matching preset name ────────────────────────────────────
    my $stations = $prefs->get('stations') || [];
    my ($match)  = grep { _station_matches($_, $freq_khz) } @$stations;
    my $preset_name = $match ? $match->{name} : undef;

    # ── Read live RDS data from tef-rds.pl output ─────────────────────────────
    my $rds = defined $freq_khz ? _read_rds($freq_khz) : undef;

    # PS name (8-char station name from RDS), trimmed
    my $ps = ($rds && $rds->{ps}) ? $rds->{ps} : '';
    $ps =~ s/^\s+|\s+$//g;

    # RadioText (up to 64 chars "now playing" text from RDS)
    my $rt = ($rds && $rds->{rt}) ? $rds->{rt} : '';
    $rt =~ s/^\s+|\s+$//g;

    # Title priority: preset name > RDS PS name > frequency label
    my $title = $preset_name // ($ps || "TEF Radio $freq_label");

    # Artist/subtitle: RadioText if available, otherwise frequency label
    my $artist = $rt || $freq_label;

    # Album: show signal quality flag if we have it
    my $album  = 'TEF FM/AM Radio';

    return {
        title  => $title,
        artist => $artist,
        album  => $album,
        cover  => undef,
        icon   => Slim::Player::ProtocolHandlers->iconForURL($url),
        type   => (defined $freq_khz && $freq_khz >= 65000) ? 'FM Radio' : 'AM Radio',
    };
}

# ─── Frequency helpers ────────────────────────────────────────────────────────

sub _url_to_khz {
    my ($freq_str) = @_;
    my $f = $freq_str + 0;

    if ($freq_str =~ /\./ || ($f >= 65 && $f < 144)) {
        # Decimal, or integer in FM-only zone (65–143 can't be AM kHz)
        return int($f * 1000 + 0.5);
    } elsif ($f >= 65000 && $f <= 108000) {
        return int($f);       # FM in kHz
    } elsif ($f >= 144 && $f <= 30000) {
        return int($f);       # AM in kHz (LW/MW/SW)
    }
    return undef;
}

sub _khz_label {
    my ($freq_khz) = @_;
    return $freq_khz >= 10000
        ? sprintf('%.1f MHz', $freq_khz / 1000)
        : sprintf('%d kHz',   $freq_khz);
}

sub _station_matches {
    my ($station, $freq_khz) = @_;
    return 0 unless defined $freq_khz;
    my $f = $station->{freq};
    my $skh = ($f >= 65 && $f <= 108) ? int($f * 1000 + 0.5) : int($f);
    return abs($skh - $freq_khz) < 10;
}

# ─── RDS file reader ──────────────────────────────────────────────────────────

sub _read_rds {
    my ($freq_khz) = @_;
    my $file = "/tmp/tefradio-rds-${freq_khz}.json";
    return undef unless -f $file;

    # Don't use stale data older than 30 seconds
    return undef if (time() - (stat $file)[9]) > 30;

    local $/;
    open(my $fh, '<', $file) or return undef;
    my $json = <$fh>;
    close $fh;

    return eval { JSON::PP->new->decode($json) };
}

# ─── Misc ─────────────────────────────────────────────────────────────────────

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
