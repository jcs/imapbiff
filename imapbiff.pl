#!/usr/bin/perl
# $Id: imapbiff.pl,v 1.1 2006/03/10 04:51:55 jcs Exp $
#
# imap biff for mac os x using growl notification
#
# by joshua stein <jcs@jcs.org>
# ssl work-around code from Nick Burch (http://gagravarr.org/code/)
#
# to configure, re-define variables in a ~/.imapbiffrc file like so:
#
#	%config = (
#		"server.name.here" => {
#			"username" => "example",
#			"password" => "password",
#			"ssl" => 1,
#			"folders" => [ "INBOX", "mailbox2", "mailbox3.whatever" ],
#		},
#		"server2" => {
#			"username" => "example",
#			... more config ...
#		},
#	);
#
#	$sleepint = 60;
#	$debug = 1;
#

use strict;
use Mail::IMAPClient;
use IO::Socket::SSL;

my (%config, $debug, $sleepint, $socktimeout);

# default sleep between check intervals is 120 seconds
$sleepint = 30;

# seconds to allow a folder check to take
$socktimeout = 10;

# read the user's config
if (-f $ENV{"HOME"} . "/.imapbiffrc") {
	my $c;
	open(C, $ENV{"HOME"} . "/.imapbiffrc") or die;
	while (my $line = <C>) {
		$c .= $line;
	}
	close(C);

	eval($c);
}

# init, build connections
foreach my $server (keys %config) {
	foreach my $folder (@{$config{$server}{"folders"}}) {
		$config{$server}{"seen"}{$folder} = ();
	}

	imap_connect($server);
}

# run forever
for(;;) {
	SERVER: foreach my $server (keys %config) {
		my $imap = $config{$server}{"imap"};

		foreach my $folder (@{$config{$server}{"folders"}}) {
			eval {
				local $SIG{"ALRM"} = sub { die; };
				alarm($socktimeout);

				if ($debug) {
					print "checking " . $server . ":" . $folder . "\n";
				}

				$$imap->select($folder) or die;
				my @unseen = ($$imap->unseen);

				foreach my $newu (@unseen) {
					my $isold = 0;
					foreach my $curu (@{$config{$server}{"seen"}{$folder}}) {
						if ($newu eq $curu) {
							$isold = 1;
							last;
						}
					}

					if (!$isold) {
						announce_message($server, $folder, $newu);
					}
				}

				$config{$server}{"seen"}{$folder} = \@unseen;

				alarm(0);
			};

			if ($@) {
				# timed out, server may be dead, drop it and reconnect
				if ($debug) {
					print "server connection timed out: " . $@ . "\n";
				}

				imap_connect($server);

				# and retry
				redo SERVER;
			}
		}

		$config{$server}{"init"} = 1;
	}

	if ($debug) {
		print "sleeping for " . $sleepint . "\n";
	}

	sleep $sleepint;
}

exit;

sub imap_connect {
	my $server = $_[0];

	$config{$server}{"init"} = 0;

	if ($config{$server}{"ssl"}) {
		my $sock = new IO::Socket::SSL(
			PeerHost => $server,
			PeerPort => "imaps",
			Timeout => 5,
		);

		$config{$server}{"sslsock"} = \$sock;
	}

	my $imap = Mail::IMAPClient->new(
		Socket => ($config{$server}{"ssl"} ? $${$config{$server}{"sslsock"}}
			: undef),
		User => $config{$server}{"username"},
		Password => $config{$server}{"password"},
		Peek => 1,
	);

	$config{$server}{"imap"} = \$imap;

	if ($config{$server}{"ssl"}) {
		$imap->State(Mail::IMAPClient::Connected);

		# get the imap server to the point of accepting a login prompt
		my $retcode;
		until ($retcode) {
			for my $line (@{$imap->_read_line}) {
				next unless $line->[Mail::IMAPClient::TYPE] eq "OUTPUT";

				($retcode) = $line->[Mail::IMAPClient::DATA] =~
					/^\*\s+(OK|BAD|NO)/i;

				if ($retcode =~ /BYE|NO /) {
					die "imap server disconnected";
				}
			}
		}

		$imap->login or die "login failed to " . $server . ": " . $!;
	}

	if ($debug) {
		print "connected to " . ($config{$server}{"ssl"} ? "ssl " : "")
			. "server " . $server . "\n";
	}
}

sub announce_message {
	my ($server, $folder, $msgno) = @_;

	if (!$config{$server}{"init"}) {
		# this may be a lot of messages, be quiet
		return;
	}

	my $imap = $config{$server}{"imap"};

	if ($debug) {
		print "new message " . $msgno . " in folder " . $folder . " on "
			. $server . "\n";
	}

	my $subject = $$imap->get_header($msgno, "Subject");
	my $from = $$imap->get_header($msgno, "From");

	system("/usr/local/bin/growlnotify",
		"-n", "imapbiff",
		"--image", "/Applications/Mail.app/Contents/Resources/drag.tiff",
		"-t", $subject,
		"-m", "From " . $from);
}
