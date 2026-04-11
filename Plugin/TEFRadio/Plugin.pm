package Plugins::TEFRadio::Plugin;

# TEF FM/AM Radio plugin for Lyrion Music Server
#
# Plays FM and AM radio directly from a TEF668X USB tuner connected to the
# LMS server. No Icecast server is required — audio is piped from the USB
# audio device through ffmpeg directly into LMS's streaming pipeline.
#
# How it works:
#   1. The plugin registers the tefradio:// URL scheme.
#   2. Station URLs look like:  tefradio://90.8  (FM MHz)
#                            or tefradio://810   (AM kHz)
#   3. When Lyrion plays such a URL, ProtocolHandler::new() spawns tef-stream.pl,
#      which does the startup handshake, tunes the TEF via serial, then exec()s
#      into ffmpeg (ALSA → MP3 → stdout).
#   4. LMS reads MP3 frames from the pipe and delivers them to the player.
#
# Installation:
#   Copy the TEFRadio/ directory into your LMS Plugins directory, restart LMS,
#   then configure via Settings → Plugins → TEF FM/AM Radio.
#
# Requirements:
#   - ffmpeg (with libmp3lame)
#   - Perl 5 (already present in Lyrion/LMS — no extra modules needed)
#   - TEF668X headless USB tuner (provides /dev/ttyACM0 + ALSA capture device)

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.tefradio',
    defaultLevel => 'WARN',
    description  => 'PLUGIN_TEFRADIO',
});

my $prefs = preferences('plugin.tefradio');

# ─── Default station presets ──────────────────────────────────────────────────
# FM stations: freq in MHz (65.0–108.0)
# AM stations: freq in kHz (144–30000)
# Users can edit these via Settings → Plugins → TEF FM/AM Radio.

my @DEFAULT_STATIONS = (
    # FM (MHz)
    { name => 'DR P1',            freq => 90.8  },
    { name => 'DR P2',            freq => 96.5  },
    { name => 'DR P3',            freq => 97.0  },
    { name => 'DR P4 Kbh',        freq => 93.9  },
    { name => 'DR P5',            freq => 103.9 },
    { name => 'Radio 100',        freq => 100.0 },
    { name => 'Hits FM',          freq => 95.9  },
    { name => 'Radio Soft',       freq => 96.1  },
    # AM (kHz)
    { name => 'BBC Radio 4',      freq => 198   },   # LW 198 kHz
    { name => 'BBC World Service', freq => 648  },   # MW 648 kHz
);

# ─── Plugin lifecycle ─────────────────────────────────────────────────────────

sub initPlugin {
    my $class = shift;

    $prefs->init({
        serial_port   => '/dev/ttyACM0',
        audio_device  => 'hw:CARD=Tuner,DEV=0',
        bitrate       => '192k',
        stations      => \@DEFAULT_STATIONS,
        stations_text => _stations_to_text(\@DEFAULT_STATIONS),
    });

    # Register the tefradio:// URL scheme
    Slim::Player::ProtocolHandlers->registerHandler(
        'tefradio', 'Plugins::TEFRadio::ProtocolHandler'
    );

    # Settings page in the LMS web UI
    if (main::WEBUI) {
        require Plugins::TEFRadio::Settings;
        Plugins::TEFRadio::Settings->new();
    }

    # Register as an OPML-based radio app (appears in My Apps and Radios)
    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'tefradio',
        menu   => 'radios',
        weight => 1,
        is_app => 1,
    );

    $log->info('TEF FM/AM Radio plugin initialised');
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

    my @items = map {
        my $f = $_->{freq};
        my ($url, $label);

        if ($f >= 65 && $f <= 108) {
            # FM: stored as MHz
            $url   = sprintf('tefradio://%.1f', $f);
            $label = sprintf('%.1f MHz', $f);
        } else {
            # AM: stored as kHz
            $url   = sprintf('tefradio://%d', int($f));
            $label = sprintf('%d kHz', int($f));
        }

        {
            name  => $_->{name},
            type  => 'audio',
            url   => $url,
            line2 => $label,
        }
    } @$stations;

    $cb->({ items => \@items });
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

sub _stations_to_text {
    my ($stations) = @_;
    return join "\n", map { "$_->{name}|$_->{freq}" } @$stations;
}

1;
