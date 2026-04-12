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
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use JSON::PP;
use POSIX ();

my $log   = logger('plugin.tefradio');
my $prefs = preferences('plugin.tefradio');

# ── Process tracking (module-level, one active stream at a time) ──────────────
my $stream_pid  = undef;   # PID of the current tef-stream.pl → ffmpeg process
my $rds_pid     = undef;   # PID of the current tef-rds.pl process
my $rds_pidfile = undef;   # Path to tef-rds.pl's pidfile

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

    # Kill any running stream and RDS processes before starting new ones.
    # This prevents process accumulation when the user switches stations.
    _kill_stream();
    _kill_rds_reader();

    # ── Create pipe + fork so we have the child PID ───────────────────────────
    # We use fork/exec instead of open('-|') so we can kill the process
    # explicitly when the stream is stopped or a new station is selected.
    my ($rd, $wr);
    unless (pipe $rd, $wr) {
        $log->error("TEFRadio: pipe() failed: $!");
        return undef;
    }

    my $pid = fork();
    unless (defined $pid) {
        $log->error("TEFRadio: fork() failed: $!");
        CORE::close($rd); CORE::close($wr);
        return undef;
    }

    if ($pid == 0) {
        # ── Child process ────────────────────────────────────────────────────
        # Redirect stdout to the write end of the pipe so ffmpeg's MP3
        # output flows to LMS.
        POSIX::dup2(CORE::fileno($wr), 1) or POSIX::_exit(1);

        # Close all inherited file descriptors (LMS has many open sockets,
        # database handles, etc.).  Closing them here prevents the child
        # (and the ffmpeg it execs into) from keeping LMS's connections alive.
        # Starts at 3 to keep stdin(0), stdout(1=pipe), stderr(2).
        for my $fd (3 .. 1023) {
            POSIX::close($fd);
        }

        exec($^X, $stream_script, $port, $freq_khz, $device, $bitrate);
        POSIX::_exit(1);
    }

    # ── Parent process ────────────────────────────────────────────────────────
    CORE::close($wr);       # Parent only needs the read end
    $stream_pid = $pid;
    $log->info("TEFRadio: stream process PID $pid");

    # Set the read end non-blocking so LMS's IO::Select event loop can
    # wait for data without stalling the server during ffmpeg's startup.
    {
        my $flags = fcntl($rd, F_GETFL, 0);
        if (defined $flags) {
            fcntl($rd, F_SETFL, $flags | O_NONBLOCK)
                or $log->warn("TEFRadio: cannot set pipe non-blocking: $!");
        }
    }

    # ── Spawn RDS background reader ───────────────────────────────────────────
    _spawn_rds_reader($rds_script, $port, $freq_khz) if -f $rds_script;

    bless $rd, $class;
    return $rd;
}

# ─── Process management ───────────────────────────────────────────────────────

sub _kill_stream {
    return unless defined $stream_pid;
    $log->info("TEFRadio: killing stream PID $stream_pid");
    kill('TERM', $stream_pid);
    waitpid($stream_pid, POSIX::WNOHANG());
    $stream_pid = undef;
}

sub _spawn_rds_reader {
    my ($script, $port, $freq_khz) = @_;

    my $json_file = "/tmp/tefradio-rds-${freq_khz}.json";
    $rds_pidfile  = "$json_file.pid";

    # Double-fork so the grandchild is re-parented to init, keeping LMS clean.
    my $pid = fork();
    if (!defined $pid) {
        $log->warn("TEFRadio: fork failed for RDS reader: $!");
        return;
    }

    if ($pid == 0) {
        # ── First child ──
        my $gc = fork();
        if (!defined $gc) { POSIX::_exit(1); }
        if ($gc != 0)     { POSIX::_exit(0); }   # first child exits

        # ── Grandchild ──
        POSIX::setsid();
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec($^X, $script, $port, $freq_khz, $json_file);
        POSIX::_exit(1);
    }

    waitpid($pid, 0);   # Reap first child; grandchild is now orphaned → init

    $log->info("TEFRadio: RDS reader started for " . _khz_label($freq_khz) .
               ", json=$json_file");
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
    $log->info("TEFRadio: stream close() — killing child processes");
    _kill_stream();
    _kill_rds_reader();
    CORE::close($self);
}

sub DESTROY {
    my $self = shift;
    # Ensure cleanup even if LMS drops the reference without calling close()
    _kill_stream();
    _kill_rds_reader();
    CORE::close($self) if defined CORE::fileno($self);
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

    my $ps = ($rds && $rds->{ps}) ? $rds->{ps} : '';
    $ps =~ s/^\s+|\s+$//g;

    my $rt = ($rds && $rds->{rt}) ? $rds->{rt} : '';
    $rt =~ s/^\s+|\s+$//g;

    my $title  = $preset_name // ($ps || "TEF Radio $freq_label");
    my $artist = $rt || $freq_label;

    return {
        title  => $title,
        artist => $artist,
        album  => 'TEF FM/AM Radio',
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
        return int($f * 1000 + 0.5);
    } elsif ($f >= 65000 && $f <= 108000) {
        return int($f);
    } elsif ($f >= 144 && $f <= 30000) {
        return int($f);
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
