#!/usr/bin/perl -w
############################################################################
#
# akal2ical v0.1.2 (09.04.2019)
# Copyright (c) 2018-2019  Lars Wessels <software@bytebox.org>
#
# Aus dem Abfuhrkalender des AfA Karlsruhe die Termine zu einem angegebenen
# Straßenzug - die leider nur als HTML-Tabelle angezeigt werden - auslesen
# und in einer iCal-Datei speichern. Da auf den Webseiten des AfA nur die
# Abfuhrtermine der kommenden drei Wochen anzeigt werden, muss dieses Skript
# regelmäßig (bspw. wöchentlich per cron) aufgerufen werden.
#
# Diese Skript gehört NICHT zum offiziellen Informationsangebot des AfA
# Karlsruhe, sondern nutzt lediglich die über die öffentlichen Webseiten des
# AfA zur Verfügung gestellten Informationen. Alle Angaben sind ohne Gewähr!
#
# Siehe auch: https://web3.karlsruhe.de/service/abfall/akal/akal.php
#
############################################################################
#
# Dieses Skript benötigt folgende Debian-Pakete (apt-get install <name>):
# - libwww-perl
# - libhtml-strip-perl 
# - libdata-ical-perl
# - libdatetime-format-ical-perl
# - libdigest-md5-perl
# - libmojolicious-perl 
#
############################################################################
#
# Copyright (c) 2018-2019  Lars Wessels <software@bytebox.org>
#
# Dieses Programm ist freie Software. Sie können es unter den Bedingungen
# der GNU General Public License, wie von der Free Software Foundation
# veröffentlicht, weitergeben und/oder modifizieren, entweder gemäß
# Version 3 der Lizenz oder (nach Ihrer Option) jeder späteren Version.
#
# Die Veröffentlichung dieses Programms erfolgt in der Hoffnung, dass es
# Ihnen von Nutzen sein wird, aber OHNE IRGENDEINE GARANTIE, sogar ohne
# die implizite Garantie der MARKTREIFE oder der VERWENDBARKEIT FÜR EINEN
# BESTIMMTEN ZWECK. Details finden Sie in der GNU General Public License.
#
# Sie sollten ein Exemplar der GNU General Public License zusammen mit diesem
# Programm erhalten haben. Falls nicht, siehe <http://www.gnu.org/licenses/>. 
#
############################################################################

use LWP::Simple;
use HTML::Strip;
use Data::ICal;
use Data::ICal::Entry::Event;
use Data::ICal::Entry::Alarm::Display;
use DateTime::Format::ICal;
use Digest::MD5 qw(md5_hex);
use Encode qw(encode_utf8);
use Mojo::DOM;
use Getopt::Long;
use vars qw($street $test);
use strict;

############################################################################

# URL zum AfA-Abfallkalender-Skript
my $base_url = 'https://web3.karlsruhe.de/service/abfall/akal/akal.php';

# Termine für diese Tonnen bzw. Müllkategorien auslesen
# mögliche Werte: schwarz od. Restmüll, grün od. Bioabfall,
# rot od. Wertstoff, blau od. Altpapier
my @bins = ('schwarz', 'grün', 'blau', 'rot'); 

# Startzeit (Stunde) für Abfuhrtermine
my $dtstart_hour = 6;

# Dauer (Minuten) des Abfuhrtermins im Kalender 
my $event_duration = 15;

# Minuten vorher erinnern (0 = keine Erinnerung)
my $alarm_min = 0;  

############################################################################

# Versionsnummer
my $p_version = 'v0.1.2';

# Kommandozeilenoptionen definieren
my $help = 0;
GetOptions('strasse=s' => \$street, 'startzeit=i' => \$dtstart_hour,
	'erinnerung=i' => \$alarm_min, 'dauer=i' => \$event_duration, 
	'test' => \$test, 'hilfe' => \$help) or &usage(); 

# Ein Straßenname muss angegeben werden...
&usage() if (!$street || $help);

# optionale Eingabewerte überprüfen
$dtstart_hour = int($dtstart_hour);
if ($dtstart_hour < 0 || $dtstart_hour > 23) {
	print STDERR "FEHLER: Die Startzeit für die Abfuhrtermine muss zwischen 0 und 23 liegen!\n\n";
	exit(5);
}
$alarm_min = int($alarm_min);
if ($alarm_min < 0 || $alarm_min > 1440 ) {
	print STDERR "FEHLER: Die Vorwarnzeit für die Abfuhrtermine muss zwischen 0 und 1440 Minuten liegen!\n";
	exit(5);
}
$event_duration = int($event_duration);
if ($event_duration < 10 || $event_duration > 180 ) {
	print STDERR "FEHLER: Die Dauer der Abfuhrtermine muss zwischen 0 und 180 Minuten liegen!\n";
	exit(5);
}

# Den angegebenen Straßennamen(teil) in Großbuchstaben
# umwandeln und passende Straßenzüge online beim AfA suchen
my @street = split(/ /, $street); $street = '';
while (my $part = shift(@street)) {
	if ($part =~ /\d/) { # Hausnummernbereiche unverändert übernehmen
		$street .= $part;
	} else {
		$street .= uc($part); # Straßennamen groß schreiben
	}
	$street =~ tr/äöü/ÄÖÜ/;
	$street =~ s/STRASSE/STRAßE/;
	$street .= " " if ($#street > -1);
}
my $street = &query_streets($street);  # Rückgabe gültiger Straßenzug

# Nun die Abfuhrtermine für den gefundenen Straßenzug abrufen
print STDERR "Sende Anfrage '".$base_url."?strasse=".$street."'...\n";
my $content = get($base_url.'?strasse='.$street);

# HTML-Tags löschen
my $stripper = HTML::Strip->new();
my $text = $stripper->parse($content);
$stripper->eof;

# Extrahierten Text in Tokens aufteilen und nach
# Schlüsselwörtern für Abfuhrtermine durchsuchen
my %pos;
my @tokens = split(/ /, $text);
foreach (0..$#tokens) {
	if ($tokens[$_] =~ /Restm/) { $pos{'Restmüll'} = $_; }
	if ($tokens[$_] =~ /Bioabfall/) { $pos{'Bioabfall'} = $_; }
	if ($tokens[$_] =~ /Wertstoff/) { $pos{'Wertstoff'} = $_; }
	if ($tokens[$_] =~ /Papier/) { $pos{'Papier'} = $_; }
	if ($tokens[$_] =~ /Haushalts/) { $pos{'Ende'} = $_; }
}

# neuen Kalender im iCalendar-Format erzeugen
my $calendar = Data::ICal->new();
my $count = 0;

# Abfuhrtermine Restmüll in Text-Tokens suchen
my @black_bin;
if ((grep { $_ =~ m/Restmüll|schwarz/ } @bins) && $pos{'Restmüll'} && $pos{'Bioabfall'}) { 
	for (my $i = $pos{'Restmüll'}; $i < $pos{'Bioabfall'}; $i++) {
		if ($tokens[$i-1] =~ /den/ && $tokens[$i] =~ /(\d\d)\.(\d\d)\.(\d{4})/) {
			push(@black_bin, $tokens[$i]);
			$calendar->add_entry(&create_event($street, 'Restmülltonne', $3, $2, $1));
			$count++;
		}
	}
	push(@black_bin, 'Keine Abfuhrtermine gefunden') if ($#black_bin < 0);
}

# Abfuhrtermine Biomüll in Text-Tokens suchen
my @green_bin;
if ((grep { $_ =~ /Biomüll|Bioabfall|grün/ } @bins) && $pos{'Bioabfall'} && $pos{'Wertstoff'}) { 
	for (my $i = $pos{'Bioabfall'}; $i < $pos{'Wertstoff'}; $i++) {
		if ($tokens[$i-1] =~ /den/ && $tokens[$i] =~ /(\d\d)\.(\d\d)\.(\d{4})/) {
			push(@green_bin, $tokens[$i]);
			$calendar->add_entry(&create_event($street, 'Bioabfall', $3, $2, $1));
			$count++;
		}
	}
	push(@green_bin, 'Keine Abfuhrtermine gefunden') if ($#green_bin < 0);
}

# Abfuhrtermine Wertstoff in Text-Tokens suchen
my @red_bin;
if ((grep { $_ =~ /Wertstoff|gelb|rot/ } @bins) && $pos{'Wertstoff'} && $pos{'Papier'}) { 
	for (my $i = $pos{'Wertstoff'}; $i < $pos{'Papier'}; $i++) {
		if ($tokens[$i-1] =~ /den/ && $tokens[$i] =~ /(\d\d)\.(\d\d)\.(\d{4})/) {
			push(@red_bin, $tokens[$i]);
			$calendar->add_entry(&create_event($street, 'Wertstofftonne', $3, $2, $1));
			$count++;
		}
	}
	push(@red_bin, 'Keine Abfuhrtermine gefunden.') if ($#red_bin < 0);
}

# Abfuhrtermine Altpapier in Text-Tokens suchen
my @blue_bin;
if ((grep { $_ =~ /apier|blau/ } @bins) && $pos{'Papier'} && $pos{'Ende'}) { 
	for (my $i = $pos{'Papier'}; $i < $pos{'Ende'}; $i++) {
		if ($tokens[$i-1] =~ /den/ && $tokens[$i] =~ /(\d\d)\.(\d\d)\.(\d{4})/) {
			push(@blue_bin, $tokens[$i]);
			$calendar->add_entry(&create_event($street, 'Altpapier', $3, $2, $1));
			$count++;
		}
	}
	push(@blue_bin, 'Keine Abfuhrtermine gefunden.') if ($#blue_bin < 0);
}

if (!$count) {
	printf STDERR "Keine Abfuhrtermine für '%s' beim AfA Karlsruhe gefunden!\n", $street;
	exit(1);
} elsif ($test) {
	printf "Kommende Abfuhrtermine für Straßenzug '%s':\n", $street;
	print "Restmüll (schwarze Tonne): ", join(' ', @black_bin),"\n" if ($#black_bin > -1);
	print "Bioabfall (grüne Tonne): ", join(' ', @green_bin),"\n" if ($#green_bin > -1);
	print "Wertstoff (rote Tonne): ", join(' ', @red_bin),"\n" if ($#red_bin > -1);
	print "Altpapier (blaue Tonne): ", join(' ', @blue_bin),"\n" if ($#blue_bin > -1);
} else {
	# Warnung ausgeben, wenn nicht für alle Müllkategorien Abfuhrtermine gefunden wurden
	print STDERR "Keine Abfuhrtemine für Restmüll (schwarze Tonne) gefunden!\n" if ($black_bin[0] =~ /Kein/);
	print STDERR "Keine Abfuhrtemine für Bioabfall (grüne Tonne) gefunden!\n" if ($green_bin[0] =~ /Kein/);
	print STDERR "Keine Abfuhrtemine für Wertstoff (rote Tonne) gefunden!\n" if ($red_bin[0] =~ /Kein/);
	print STDERR "Keine Abfuhrtemine für Altpapier (blaue Tonne) gefunden.\n" if ($blue_bin[0] =~ /Kein/);

	# Abfuhrtermine in iCal-Kalenderdatei *.ics speichern
	my %replace = (	"Ä" => "Ae", "Ü" => "Ue", "Ö" => "Oe", "ß" => "ss", " " => "_");
	$street =~ s/(Ä|Ü|Ö|ß|\s+)/$replace{$1}/g;
	my $ical_file = lc($street).'.ics';
	open(ICAL, ">$ical_file") or die "FEHLER: kann die Datei '$ical_file' nicht erstellen: $!\n";
	my $ical = $calendar->as_string;
	$ical =~ s?PRODID.+?PRODID:-//software\@bytebox.org//akal2ical $p_version//DE?;
	print ICAL $ical;
	close(ICAL);
	printf STDERR "Es wurden %d Abfuhrtemine in Datei '$ical_file' gespeichert.\n", $count;
}

exit(0);



# einen Kalendereintrag (event) für einen Abfuhrtermin erzeugen
sub create_event() {
	my ($street, $bin, $year, $month, $day) = @_;
	my $uid = md5_hex($bin.$year.$month.$day);
	my $vevent = Data::ICal::Entry::Event->new();
	$vevent->add_properties(
		uid => $uid,
		summary => $bin,
		description => "Abfuhrtermin $bin für $street",
		location => "$street, Karlsruhe",
		transp => "TRANSPARENT",
		class => "PUBLIC",
		url => $base_url,
		dtstamp => DateTime::Format::ICal->format_datetime(DateTime->now),
		dtstart => DateTime::Format::ICal->format_datetime(DateTime->new(
			day => $day, month => $month, year => $year,
			hour => $dtstart_hour, minute => 00)),
		dtend => DateTime::Format::ICal->format_datetime(DateTime->new(
			day => $day, month => $month, year => $year,	
			hour => $dtstart_hour, minute => $event_duration))
	);

	# ggf. Erinnerung an Abfuhrtermin erstellen
	if (int($alarm_min) > 0) {
		my $valarm = Data::ICal::Entry::Alarm::Display->new();
		$valarm->add_properties(
	    	description => $bin,
			trigger => '-PT'.$alarm_min.'M'
		);
		$vevent->add_entry($valarm);
	}

	return $vevent;
}


# alle bekannten Straßenzüge beim AfA nach gegebener Zeichenkette durchsuchen
sub query_streets() {
	my $query = shift;

	printf STDERR "Nach dem Straßenzug '%s' beim AfA Karlsruhe suchen...\n", $query;
	my $html = get($base_url.'?von=A&bis=Z'); # alle Straßenzüge beim AfA abrufen
	my $dom = Mojo::DOM->new($html);
	my @streets;

	# <select> Tag suchen
	foreach my $select ($dom->find('select')->each ) {
  		# alle <option> Tags durchlaufen
  		foreach my $opt ($select->find('option')->each ) {
			my $street = encode_utf8($opt->text);
			if ($street =~ /^$query$/i) {
				return $street;
			} else {
				push(@streets, $street) if ($street =~ /^$query/i);
			}
		}
	}

	if ($#streets > 0) {
		printf STDERR "Es wurden %d passende Straßenzüge gefunden. Bitte einen der ", $#streets+1;
		print STDERR "folgenden\nBezeichner zur Abfrage der Abfuhrtermine verwenden:\n";
		foreach my $street (@streets) {
			print STDERR "- '$street'\n";
		}
		exit(2);
	} elsif ($#streets < 0) {
		print STDERR "Keinen passenden Straßenzug zur Anfrage '$query' gefunden.\n";
		exit(3);
	}
	return $streets[0];
}


# Hilfe zum Aufruf des Skript ausgeben
sub usage() {
	select STDERR;
	printf "\nakal2ical %s - Copyright (c) 2018-2019 Lars Wessels <software\@bytebox.org>\n", $p_version;
	print "Abfuhrtermine des AfA Karlsruhe für den angegebenen Straßenzug abrufen\n";
	print "und als iCal-Datei (*.ics) speichern. Alle Angaben sind ohne Gewähr!\n\n";
	print "Aufruf: akal2ical.pl --strasse '<strassenname oder -namensteil>'\n";
	print "Optionen: --startzeit <stunde>   : Startzeit für Abfuhrtermine (Standard 6 Uhr)\n";
	print "          --dauer <minuten>      : Dauer der Abfuhrtermine (Standard 15 Min.)\n";
	print "          --erinnerung <minuten> : Minuten vorher erinnern (Standard aus)\n";
	print "          --test                 : gefundene Abfuhrtermine nur anzeigen\n";
	print "          --hilfe                : diese Kurzhilfe anzeigen\n\n";
	print "Den Straßennamen inkl. Hausnummerbereich in Hochkommata einschließen!\n";
	print "Beispiel: akal2ical.pl --strasse 'Weltzienstraße 14-Ende'\n\n";
	print "Dieses Programm wird unter der GNU General Public License v3 bereitsgestellt,\n";
	print "in der Hoffnung, dass es nützlich sein wird, aber OHNE JEDE GEWÄHRLEISTUNG;\n";
	print "sogar ohne die implizite Gewährleistung der MARKTFÄHIGKEIT oder EIGNUNG FÜR\n";
	print "EINEN BESTIMMTEN ZWECK. Weitere Details siehe https://www.gnu.org/licenses/\n\n";
	exit(4);
}
