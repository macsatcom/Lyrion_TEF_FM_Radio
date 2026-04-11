package Plugins::TEFRadio::Settings;

# Settings page for the TEF FM/AM Radio plugin.
# Accessible via LMS web UI: Settings → Plugins → TEF FM/AM Radio

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

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

    # Always regenerate the textarea from the saved station array
    my $stations = $prefs->get('stations') || [];
    $params->{stations_text} = join "\n", map { "$_->{name}|$_->{freq}" } @$stations;

    return $class->SUPER::handler($client, $params);
}

1;
