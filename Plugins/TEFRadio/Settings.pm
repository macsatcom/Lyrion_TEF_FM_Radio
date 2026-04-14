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

my $log   = logger('plugin.tefradio');
my $prefs = preferences('plugin.tefradio');

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
    if ($params->{runScan}) {
        my $script = catfile(_plugin_dir(), 'tef-scan.pl');
        my $port   = $prefs->get('serial_port') // '/dev/ttyACM0';

        $log->info("TEFRadio settings: starting FM band scan on $port");

        my $json = '';
        if (open my $fh, '-|', $^X, $script, $port) {
            local $/; $json = <$fh>; CORE::close($fh);
        } else {
            $log->error("TEFRadio settings: failed to start tef-scan.pl: $!");
        }

        my $results = eval { JSON::PP->new->decode($json) } // [];

        if (@$results) {
            my @stations = map {
                { name => $_->{name}, freq => $_->{freq_mhz} }
            } @$results;
            $prefs->set('stations', \@stations);
            $log->info(sprintf('TEFRadio settings: scan saved %d stations', scalar @stations));
            $params->{scan_message} = sprintf('Scan complete — found %d stations. Station list updated.', scalar @stations);
        } else {
            $params->{scan_message} = 'Scan complete — no stations found above threshold.';
            $log->warn('TEFRadio settings: scan returned no stations');
        }
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

sub _plugin_dir {
    if (my $path = $INC{'Plugins/TEFRadio/Settings.pm'}) {
        $path =~ s{/Settings\.pm$}{};
        return $path;
    }
    return '.';
}

1;
