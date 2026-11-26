package Plugins::TEFRadio::Settings;

# Settings page for the TEF FM/AM Radio plugin.
# Accessible via LMS web UI: Settings → Plugins → TEF FM/AM Radio

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use File::Spec::Functions qw(catfile);
use JSON::PP;
use Proc::Background;
use Slim::Utils::Timers;
use Time::HiRes ();

my $log   = logger('plugin.tefradio');
my $prefs = preferences('plugin.tefradio');

my $scan_proc;      # Proc::Background object while a scan is running
my $scan_message;   # result text, shown once on the next page load
my $scan_started;   # time() when the current scan was started
my $SCAN_TIMEOUT = 300;   # seconds; tef-scan.pl limits itself to ~3 min

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_TEFRADIO_SETTINGS');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/TEFRadio/settings/basic.html');
}

sub prefs {
    return ($prefs, qw(serial_port audio_device bitrate stations_text));
}

sub handler {
    my ($class, $client, $params) = @_;

    if ($params->{saveSettings}) {
        my $raw = $params->{stations_text} // '';

        my @stations;
        for my $line (split /\r?\n/, $raw) {
            $line =~ s/^\s+|\s+$//g;
            next unless $line;

            my ($name, $freq) = split /\|/, $line, 2;
            next unless defined $name && defined $freq;

            $name =~ s/^\s+|\s+$//g;
            $freq =~ s/^\s+|\s+$//g;

            if ($name ne '' && $freq =~ /^\d+\.?\d*$/) {
                my $f = $freq + 0;
                # FM: 65–108 MHz (stored as MHz)
                # AM: 144–30000 kHz LW/MW/SW (stored as kHz)
                if (($f >= 65 && $f <= 108) || ($f >= 144 && $f <= 30000)) {
                    push @stations, { name => $name, freq => $f };
                } else {
                    $log->warn("TEFRadio settings: skipping out-of-range frequency $f ($name)");
                }
            }
        }

        $prefs->set('stations', \@stations);
        $log->info('TEFRadio settings: saved ' . scalar(@stations) . ' station presets');
    }

    # ── FM band scan (triggered by the Scan button) ───────────────────────────
    # The scan takes 20–60 s.  It runs as a background process so LMS (which is
    # single-threaded) keeps serving players; a timer collects the result.
    if ($params->{runScan} && !_scan_running()) {
        _start_scan();
    }

    $params->{scan_running} = _scan_running() ? 1 : 0;
    if (!$params->{scan_running} && defined $scan_message) {
        $params->{scan_message} = $scan_message;
        $scan_message = undef;   # show once
    }

    # Always regenerate the textarea from the saved station array
    my $stations = $prefs->get('stations') || [];
    $params->{stations_text} = join "\n", map { "$_->{name}|$_->{freq}" } @$stations;

    # Check that LMS can actually open the configured serial port
    my $port = $prefs->get('serial_port') // '/dev/ttyACM0';
    $params->{port_path} = $port;
    if (!-e $port) {
        $params->{port_warning} = 'not_found';
    } elsif (!-r $port || !-w $port) {
        $params->{port_warning} = 'permission';
    } else {
        $params->{port_warning} = '';
    }

    return $class->SUPER::handler($client, $params);
}

# ── Background FM scan ────────────────────────────────────────────────────────

my $SCAN_OUT = '/tmp/tefradio-scan.json';
my $SCAN_LOG = '/tmp/tefradio-scan.log';

sub _scan_running { return $scan_proc && $scan_proc->alive ? 1 : 0 }

sub _start_scan {
    my $script = catfile(_plugin_dir(), 'tef-scan.pl');
    my $port   = $prefs->get('serial_port') // '/dev/ttyACM0';
    my $q      = sub { my $v = shift; $v =~ s/'/'\\''/g; "'$v'" };

    unlink $SCAN_OUT;
    my $cmd = join(' ', map { $q->($_) } $^X, $script, $port)
            . ' > ' . $q->($SCAN_OUT) . ' 2>> ' . $q->($SCAN_LOG);

    $log->info("TEFRadio settings: starting background FM scan on $port");
    $scan_proc = eval { Proc::Background->new($cmd) };
    if (!$scan_proc) {
        $log->error("TEFRadio settings: failed to start tef-scan.pl: " . ($@ || $!));
        $scan_message = 'Scan could not be started — see the LMS log.';
        return;
    }
    $scan_started = time();
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 2, \&_check_scan);
}

sub _check_scan {
    if (_scan_running() && time() - $scan_started > $SCAN_TIMEOUT) {
        $log->warn("TEFRadio settings: scan exceeded ${SCAN_TIMEOUT}s, stopping it");
        $scan_proc->die;
        $scan_proc    = undef;
        $scan_message = 'Scan took too long and was stopped — see /tmp/tefradio-scan.log.';
        return;
    }
    if (_scan_running()) {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 2, \&_check_scan);
        return;
    }
    $scan_proc = undef;

    my $json = '';
    if (open my $fh, '<', $SCAN_OUT) { local $/; $json = <$fh>; CORE::close($fh) }
    my $results = eval { JSON::PP->new->utf8->decode($json) };

    if (ref $results eq 'ARRAY' && @$results) {
        my @stations = map { { name => $_->{name}, freq => $_->{freq_mhz} } } @$results;
        $prefs->set('stations', \@stations);
        $log->info(sprintf('TEFRadio settings: scan saved %d stations', scalar @stations));
        $scan_message = sprintf('Scan complete — found %d stations. Station list updated.', scalar @stations);
    } else {
        $log->warn('TEFRadio settings: scan returned no stations');
        $scan_message = 'Scan complete — no stations found above threshold.';
    }
}

sub _plugin_dir {
    if (my $path = $INC{'Plugins/TEFRadio/Settings.pm'}) {
        $path =~ s{/Settings\.pm$}{};
        return $path;
    }
    return '.';
}

1;
