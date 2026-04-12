package Plugins::TEFRadio::ProtocolHandler;

# Protocol handler for tefradio:// URLs.
#
# Audio streaming uses LMS's native transcoder pipeline (like Spotty):
#   custom-types.conf  — registers the 'tef' format
#   custom-convert.conf — maps tef→mp3 via tef-stream.pl
#
# LMS starts tef-stream.pl as a transcoder subprocess.  tef-stream.pl:
#   1. Kills any running RDS reader
#   2. Tunes the TEF chip via serial
#   3. Spawns tef-rds.pl as a background daemon
#   4. exec()s ffmpeg → raw MP3 on stdout → LMS reads and sends to player
#
# This module is responsible only for:
#   - Protocol registration and capabilities
#   - getMetadataFor() — reads live RDS data from /tmp/tefradio-rds-*.json
#
# URL frequency conventions:
#   tefradio://90.8    FM 90.8 MHz  (decimal → MHz)
#   tefradio://100     FM 100 MHz   (integer 65–108 → MHz)
#   tefradio://90800   FM 90.8 MHz  (integer ≥65000 → kHz)
#   tefradio://810     AM 810 kHz   (integer 144–30000 → kHz)

use strict;
use warnings;

use base qw(Slim::Formats::RemoteStream);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use File::Spec::Functions qw(catfile);
use JSON::PP;

my $log   = logger('plugin.tefradio');
my $prefs = preferences('plugin.tefradio');

# ─── Protocol capabilities ────────────────────────────────────────────────────

sub isRemote        { 1 }
sub canSeek         { 0 }
sub isRewindable    { 0 }
sub canDirectStream { 0 }
sub getFormatForURL { 'tef' }
sub contentType     { 'tef' }

# Called by LMS before starting the transcoder for each new track.
# Returning 'tef' tells LMS to look up the tef-mp3 conversion rule.
sub formatOverride  { 'tef' }

# ─── Metadata ─────────────────────────────────────────────────────────────────

sub getMetadataFor {
    my ($class, $client, $url) = @_;

    my ($freq_str) = $url =~ m{^tefradio://(.+)$};
    my $freq_khz   = defined $freq_str ? _url_to_khz($freq_str) : undef;
    my $freq_label = defined $freq_khz ? _khz_label($freq_khz)  : 'Radio';

    my $stations = $prefs->get('stations') || [];
    my ($match)  = grep { _station_matches($_, $freq_khz) } @$stations;
    my $preset_name = $match ? $match->{name} : undef;

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
    CORE::close($fh);

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
