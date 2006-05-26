#!/usr/bin/perl
# $Id: imapbiff.pl,v 1.4 2006/05/26 16:23:51 jcs Exp $
#
# imap biff for mac os x using growl notification
#
# Copyright (c) 2006 joshua stein <jcs@jcs.org>
# ssl work-around code from Nick Burch (http://gagravarr.org/code/)
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 3. The name of the author may not be used to endorse or promote products
#    derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 

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
			};

			alarm(0);

			if ($@) {
				# timed out, server may be dead, drop it and reconnect
				if ($debug) {
					print "server connection timed out: " . $@ . "\n";
				}

				# throttle
				sleep $sleepint;

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
	my ($sock, $imap);

	$config{$server}{"init"} = 0;

	if ($debug) {
		print "connecting to " . ($config{$server}{"ssl"} ? "ssl " : "")
			. "server " . $server . "\n";
	}

	if ($config{$server}{"ssl"}) {
		$sock = new IO::Socket::SSL(
			PeerHost => $server,
			PeerPort => ($config{$server}{"port"} ? $config{$server}{"port"}
				: 993),
			Timeout => 5,
		) or die "no ssl socket: " . $@;

		$config{$server}{"sslsock"} = \$sock;
	}

	$imap = Mail::IMAPClient->new(
		Socket => ($config{$server}{"ssl"} ? ${$config{$server}{"sslsock"}}
			: undef),
		User => $config{$server}{"username"},
		Password => $config{$server}{"password"},
		Peek => 1,
		Debug => $debug,
	) or die "no imap connection: " . $@;

	$config{$server}{"imap"} = \$imap;

	if ($config{$server}{"ssl"}) {
		$imap->State(Mail::IMAPClient::Connected);

		# get the imap server to the point of accepting a login prompt
		my $retcode;
		until ($retcode) {
			my $d = $imap->_read_line or return undef;

			for my $line (@$d) {
				next unless $line->[Mail::IMAPClient::TYPE] eq "OUTPUT";

				($retcode) =
					$line->[Mail::IMAPClient::DATA] =~ /^\*\s+(OK|BAD|NO)/i;

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

	# strip high ascii because growlnotify likes to segfault on it
	$subject =~ tr/\000-\177//cd; 
	$from =~ tr/\000-\177//cd; 

	system("/usr/local/bin/growlnotify",
		"-n", "imapbiff",
		"--image", "/Applications/Mail.app/Contents/Resources/drag.tiff",
		"-t", $subject,
		"-m", "From " . $from);
}
