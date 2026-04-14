package Plugins::TEFRadio::Plugin;

# TEF FM/AM Radio plugin for Lyrion Music Server
#
# Plays FM and AM radio directly from a TEF668X USB tuner.
# No Icecast server is required — audio is piped from the USB audio device
# through ffmpeg directly into LMS's streaming pipeline.
#
# Features:
#   - FM (65–108 MHz) and AM (LW/MW/SW, 144–30000 kHz)
#   - Live RDS metadata: station name (PS) and "now playing" text (RadioText)
#     displayed in the LMS now-playing screen
#   - FM band scan: finds stations automatically and names them from RDS PS
#     (quick scan) or after tuning each one briefly (deep scan)
#
# URL conventions:
#   tefradio://90.8   FM 90.8 MHz
#   tefradio://810    AM 810 kHz MW
#   tefradio://198    AM 198 kHz LW

use strict;
use warnings;

use vars qw($VERSION);
$VERSION = '0.36';

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use File::Spec::Functions qw(catfile);
use Slim::Player::TranscodingHelper;

use Plugins::TEFRadio::Settings;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.tefradio',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_TEFRADIO',
});

my $prefs = preferences('plugin.tefradio');

# ─── Default station presets ──────────────────────────────────────────────────
# FM stations: freq in MHz (65.0–108.0)
# AM stations: freq in kHz (144–30000)

my @DEFAULT_STATIONS = (
    # FM (MHz)
    { name => 'DR P1',             freq => 90.8  },
    { name => 'DR P2',             freq => 96.5  },
    { name => 'DR P3',             freq => 97.0  },
    { name => 'DR P4 Kbh',         freq => 93.9  },
    { name => 'DR P5',             freq => 103.9 },
    { name => 'Radio 100',         freq => 100.0 },
    { name => 'Hits FM',           freq => 95.9  },
    { name => 'Radio Soft',        freq => 96.1  },
    # AM (kHz)
    { name => 'BBC Radio 4',       freq => 198   },   # LW 198 kHz
    { name => 'BBC World Service', freq => 648   },   # MW 648 kHz
);

# ─── Plugin lifecycle ─────────────────────────────────────────────────────────

sub initPlugin {
    my $class = shift;

    $log->info("TEF FM/AM Radio plugin v$VERSION initialising");

    $prefs->init({
        serial_port   => '/dev/ttyACM0',
        audio_device  => 'hw:CARD=Tuner,DEV=0',
        bitrate       => '192k',
        stations      => \@DEFAULT_STATIONS,
        stations_text => _stations_to_text(\@DEFAULT_STATIONS),
    });

    Slim::Player::ProtocolHandlers->registerHandler(
        'tefradio', 'Plugins::TEFRadio::ProtocolHandler'
    );

    Plugins::TEFRadio::Settings->new();

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'tefradio',
        menu   => 'radios',
        weight => 1,
    );

    $log->info("TEF FM/AM Radio plugin v$VERSION ready — serial=" .
        $prefs->get('serial_port') . ' device=' . $prefs->get('audio_device'));
}

# Called after all plugins are initialised and custom-convert.conf is loaded.
# This is the correct place to patch the transcoding table (Spotty does the same).
sub postinitPlugin { if (main::TRANSCODING) {
    my $class = shift;

    # Inject actual paths/prefs into the transcoding command loaded from
    # custom-convert.conf (placeholders: TSCRIPT SERL DEVI BITR).
    _updateTranscodingTable();

    # Re-inject whenever the user saves new settings
    $prefs->setChange(sub { _updateTranscodingTable() },
        qw(serial_port audio_device bitrate));
} }

sub _updateTranscodingTable {
    my $dir    = _plugin_dir();
    my $script = $^X . ' ' . catfile($dir, 'tef-stream.pl');
    my $port   = $prefs->get('serial_port')  // '/dev/ttyACM0';
    my $device = $prefs->get('audio_device') // 'hw:CARD=Tuner,DEV=0';
    my $bitrate = $prefs->get('bitrate')     // '192k';

    my $cmd_table = Slim::Player::TranscodingHelper::Conversions();
    for my $key (keys %$cmd_table) {
        next unless $key =~ /^tef-/;
        $cmd_table->{$key} =~ s{TSCRIPT}{$script}g;
        $cmd_table->{$key} =~ s{SERL}{$port}g;
        $cmd_table->{$key} =~ s{DEVI}{$device}g;
        $cmd_table->{$key} =~ s{BITR}{$bitrate}g;
    }

    $log->info("TEFRadio: transcoder command → $script \$URL\$ $port $device $bitrate");
}

sub getDisplayName { 'PLUGIN_TEFRADIO' }

sub getIcon {
    my $class = shift;
    return $class->_pluginDataFor('icon');
}

# ─── OPML station browser ─────────────────────────────────────────────────────

sub handleFeed {
    my ($client, $cb, $args) = @_;

    my $stations = $prefs->get('stations') || \@DEFAULT_STATIONS;

    my @items = map { _station_to_opml($_) } @$stations;
    $cb->({ items => \@items });
}


# ─── Helpers ──────────────────────────────────────────────────────────────────

sub _station_to_opml {
    my ($s) = @_;
    my $f = $s->{freq};
    my ($url, $label);
    if ($f >= 65 && $f <= 108) {
        $url   = sprintf('tefradio://%.1f', $f);
        $label = sprintf('%.1f MHz', $f);
    } else {
        $url   = sprintf('tefradio://%d', int($f));
        $label = sprintf('%d kHz', int($f));
    }
    return {
        name  => $s->{name},
        type  => 'audio',
        url   => $url,
        line2 => $label,
    };
}

sub _stations_to_text {
    my ($stations) = @_;
    return join "\n", map { "$_->{name}|$_->{freq}" } @$stations;
}

sub _plugin_dir {
    if (my $path = $INC{'Plugins/TEFRadio/Plugin.pm'}) {
        $path =~ s{/Plugin\.pm$}{};
        return $path;
    }
    for my $dir (Slim::Utils::OSDetect::dirsFor('Plugins')) {
        return catfile($dir, 'TEFRadio') if -d catfile($dir, 'TEFRadio');
    }
    return '.';
}

1;
