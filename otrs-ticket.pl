#!/usr/bin/perl -Tw

# Copyright 2012 - Jean-Sebastien Morisset - http://surniaulula.com/
#
# Create and update OTRS tickets from Centreon, Nagios, other monitoring tools,
# or the command-line.
#
#   Blog Page: http://surniaulula.com/2012/10/24/create-and-update-otrs-tickets-from-the-command-line/
# Google Code: https://code.google.com/p/otrs-ticket/
#
# This script is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# This script is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
# details at http://www.gnu.org/licenses/.
#
# Centreon / Nagios Host Notification:
#
#	$USER1$/otrs-ticket.pl --otrs_user="user" --otrs_pass="pass" --otrs_server="server.domain.com:80" --problem_id="$HOSTPROBLEMID$" --problem_id_last="$LASTHOSTPROBLEMID$" --event_type="$NOTIFICATIONTYPE$" --event_date="$LONGDATETIME$" --event_host="$HOSTNAME$" --event_addr="$HOSTADDRESS$" --event_desc="$SERVICEACKAUTHOR$ $SERVICEACKCOMMENT$" --event_state="$HOSTSTATE$" --event_output="$HOSTOUTPUT$"
#
# Centreon / Nagios Service Notification:
#
#	 $USER1$/otrs-ticket.pl --otrs_user="user" --otrs_pass="pass" --otrs_server="server.domain.com:80" --problem_id="$SERVICEPROBLEMID$" --problem_id_last="$LASTSERVICEPROBLEMID$" --event_type="$NOTIFICATIONTYPE$" --event_date="$LONGDATETIME$" --event_host="$HOSTALIAS$" --event_addr="$HOSTADDRESS$" --event_desc="$SERVICEDESC$" --event_state="$SERVICESTATE$" --event_output="$SERVICEOUTPUT$"
#
# Requirements for OTRS:
#
# 1) The GenericTicketConnector.yml must be installed
#    (http://source.otrs.org/viewvc.cgi/otrs/development/webservices/GenericTicketConnector.yml?view=co)
# 1) A user name (aka "Agent") and password to for the script
# 2) A ticket queue (defaults to "UNIX" -- see the %otrs_defaults variable)
# 3) An 'unknown' customer username (see the %otrs_defaults variable)
# 5) An 'Infrastructure::Server::Unix/Linux' OTRS Service (see the
#    %otrs_defaults variable).
# 4) An OTRS State named 'recovered' (see the %otrs_states variable).
# 6) Dynamic fields ProblemID, HostName, HostAddress, and ServiceDesc.

# Changes:
#
# v1.2.1:
# - Modified the 'open()' function for the CSV file to use a proper variable name.
# - Passed the script through perlcritic to make sure all syntax is OK.
#
# v1.2
# - Renamed the event_id and event_id_last options to problem_id and problem_id_last.
# - Added %otrs_states to change ticket state depending on the event_type value.
# 
# v1.1
# - Added inet_aton/inet_ntoa function calls to resolve OTRS server IP before launching SOAP (just to make sure the resolver works).
# - Added --notif_id and --notif_number command line argument.
# - Renamed Nagios *EVENTID variables to *PROBLEMID.


use strict;
use Socket;
use Getopt::Long;
use DBI;
use DBD::SQLite;
use SOAP::Lite;
use Log::Handler;

my $VERSION = '1.2.1';

# hard-code paths to prevent warning from taint mode
my $logfile = '/var/tmp/otrs-ticket.log';
my $csvfile = '/var/tmp/otrs-ticket.csv';
my $dbname = '/var/tmp/otrs-ticket.sqlite';
my $dbuser = '';
my $dbpass = '';
my $dbtable = 'TicketIDAssoc';
# if the event_type is known, then change the ticket state
my %otrs_states = (
	'ACKNOWLEDGEMENT' => 'Aberto',
	'RECOVERY' => 'recovered',
);
my %otrs_defaults = (
	'Queue' => 'REPAD-Monitoramento',
	'PriorityID' => '3',
	'Type' => 'Incident',
	'State' => 'new',
	'CustomerUser' => 'unknown',
	#'Service' => 'Infrastructure::Server::Unix/Linux',
);
my $TicketID;
my $TicketNumber;
my $ArticleID;

# read command line options
my %opt = ();
GetOptions(\%opt, 'verbose', 'otrs_user=s', 'otrs_pass=s', 'otrs_server=s',
'problem_id=s', 'problem_id_last=s', 'event_type=s', 'event_date=s',
'event_host=s', 'event_addr=s', 'event_desc=s', 'event_state=s',
'event_output=s', 'otrs_customer=s', 'otrs_queue=s', 'otrs_priority=s',
'otrs_type=s', 'otrs_state=s', 'otrs_service=s');

# silently strip anything non-numeric from integer fields (where-as
# using GetOptions's '=i' would throw an error)
for ( qw( problem_id problem_id_last ) ) { 
	$opt{$_} =~ s/[^0-9]// if (defined $opt{$_});
}
# clear "empty" event_desc from host notification
$opt{'event_desc'} =~ s/^\$ \$$//;

# beautify some option names for logging, ticket text, etc.
my %event_info = (
	'ProblemID' => $opt{'problem_id'} ||= 0,
	'ProblemIDLast' => $opt{'problem_id_last'} ||= 0,
	'EventType' => $opt{'event_type'} ||= '',
	'EventDate' => $opt{'event_date'} ||= '',
	'EventHostName' => $opt{'event_host'} ||= '',
	'EventHostAddress' => $opt{'event_addr'} ||= '',
	'EventServiceDesc' => $opt{'event_desc'} ||= '',
	'EventState' => $opt{'event_state'} ||= '',
	'EventOutput' => $opt{'event_output'} ||= '',
);

if (defined $opt{'problem_id'} && $opt{'problem_id'} == 0
	&& defined $opt{'problem_id_last'} && $opt{'problem_id_last'} > 0) {
	$opt{'problem_id'} = $opt{'problem_id_last'};
}

# define a new ticket state if one wasn't given on the command line, and the
# event_type has been defined in %otrs_states.
$opt{'otrs_state'} = $otrs_states{$opt{'event_type'}}
	if ( !$opt{'otrs_state'} 
		&& defined $otrs_states{$opt{'event_type'}}
		&& $otrs_states{$opt{'event_type'}} );

my $stdout = $opt{'verbose'} ? 'debug' : 'info';
my $log = Log::Handler->new();
$log->add(
	file => {
		filename => $logfile,
		maxlevel => 'debug',
		timeformat => '%Y%m%d-%H%M%S',
        },
	screen => {
		log_to   => 'STDOUT',
		maxlevel => $stdout,
		timeformat => '%Y%m%d-%H%M%S',
	},
);

$log->info("START of $0 v$VERSION script");

#
# Log the command line options to a csv file to keep a history (even if some
# arguments might be missing).
#
$log->debug("Saving event_info fields to $csvfile.");
unless (open (my $csv_fh, ">>", $csvfile)) { $log->critical("Error opening ".$csvfile.": ".$!); &DoExit(1); }
unless (-s $csvfile) { for (sort keys %event_info) { print $csv_fh '"', $_, '",'; }; print $csv_fh "\n"; }
for (sort keys %event_info) { print $csv_fh '"', $event_info{$_}, '",'; }; print $csv_fh "\n";
close ($csv_fh);

#
# Check all essential opt values and exit if some missing.
#
my @essential_opts = sort qw( otrs_user otrs_pass otrs_server problem_id event_type
event_date event_host event_addr event_state event_output );

# print the whole list before exiting
for (@essential_opts) {
	$log->error("Required argument $_ not defined or empty!") 
		if (!defined $opt{$_} || $opt{$_} eq '');
}
for (@essential_opts) { &DoExit(1) if (! $opt{$_}); }

for (sort keys %opt) {
	if ($_ eq 'otrs_pass' ) { $log->debug("Argument $_ = ********") }
	else { $log->debug("Argument $_ = $opt{$_}"); }
}

#
# Open the database and create the table(s) if necessary
#
my $dsn = "DBI:SQLite:dbname=$dbname";
my $dbh = DBI->connect($dsn, $dbuser, $dbpass);
if ($DBI::err) { $log->critical($DBI::errstr); &DoExit(1); }

$dbh->do("PRAGMA foreign_keys = ON");
$dbh->do("CREATE TABLE IF NOT EXISTS $dbtable ( 
	ProblemID INTEGER PRIMARY KEY, 
	TicketID INTEGER NOT NULL, 
	TicketNumber INTEGER )");
($TicketID, $TicketNumber) = $dbh->selectrow_array("SELECT TicketID, TicketNumber 
	FROM $dbtable WHERE ProblemID=?", undef, $opt{'problem_id'});

#
# Configuration for OTRS connection and definition of available Ticket /
# Article fields (used when constructing the SOAP data).
#
my %otrs = (
	'UserLogin' => $opt{'otrs_user'},
	'Password' => $opt{'otrs_pass'},
	'URL' => 'http://'.$opt{'otrs_server'}.'/otrs/nph-genericinterface.pl/Webservice/GenericTicketConnector',
	'NameSpace' => 'http://www.otrs.org/TicketConnector/',
	'TicketID' => '',
	'TicketNumber' => '',
	'Operation' => '',
	'TicketFields' => [
		'Title',
		'QueueID',
		'Queue',
		'TypeID',
		'Type',
		'ServiceID',
		'Service',
		'SLAID',
		'SLA',
		'StateID',
		'State',
		'PriorityID',
		'Priority',
		'OwnerID',
		'Owner',
		'ResponsibleID',
		'Responsible',
		'CustomerUser',
	],
	'ArticleFields' => [ 
		'ArticleTypeID',
		'ArticleType',
		'SenderTypeID',
		'SenderType',
		'Subject',
		'Body',
		'ContentType',
		'Charset',
		'MimeType',
		'HistoryType',
		'HistoryComment',
		'AutoResponseType',
		'TimeUnit',
		'NoAgentNotify',
		'ForceNotificationToUserID',
		'ExcludeNotificationToUserID',
		'ExcludeMuteNotificationToUserID',
	],
);


#
# Define the ticket details here.
#
my %ticket;
if ($TicketID) {
	$log->info("Found ProblemID $opt{'problem_id'} in database");
	$log->info("Updating TicketID $TicketID (TicketNumber $TicketNumber)");
	$otrs{'Operation'} = 'TicketUpdate';
	$otrs{'TicketID'} = $TicketID;
	# if we have a different state (than new) defined, then use it, otherwise leave as-is
	if (defined $opt{'otrs_state'} && $opt{'otrs_state'}) {
		$ticket{'State'} = $opt{'otrs_state'};
		$log->notice('Updating Ticket State to "'.$ticket{'State'}.'"');
	}
} else {
	$log->debug("ProblemID ".$opt{'problem_id'}." not found in database");
	$log->info("Creating new OTRS Ticket for ProblemID ".$opt{'problem_id'});
	$otrs{'Operation'} = 'TicketCreate';
	%ticket = (
		'Queue' => $opt{'otrs_queue'} ||= $otrs_defaults{'Queue'},
		'PriorityID' => $opt{'otrs_priority'} ||= $otrs_defaults{'PriorityID'},
		'Type' => $opt{'otrs_type'} ||= $otrs_defaults{'Type'},
		'State' => $opt{'otrs_state'} ||= $otrs_defaults{'State'},
		'Service' => $opt{'otrs_service'} ||= $otrs_defaults{'Service'},
		'DynamicField' => {
			'ProblemID' => $opt{'problem_id'},
			'HostName' => $opt{'event_host'},
			'HostAddress' => $opt{'event_addr'},
			'ServiceDesc' => $opt{'event_desc'},
		},
	);
}

# Common ticket fields / values for TicketUpdate or TicketCreate.
$ticket{'CustomerUser'} = $opt{'otrs_customer'} ||= $otrs_defaults{'CustomerUser'};
$ticket{'ContentType'} = 'text/plain; charset=utf8';
$ticket{'SenderType'} = 'system';
$ticket{'Title'} = $opt{'event_type'}.': '.$opt{'event_host'};
$ticket{'Title'} .= '/'.$opt{'event_desc'} if ($opt{'event_desc'});
$ticket{'Title'} .= ' is '.$opt{'event_state'};
$ticket{'Subject'} = $ticket{'Title'};
$ticket{'Body'} = $opt{'event_output'}."\n\n";

# Append all the "event_info" fields to the ticket for reference.
for (sort keys %event_info) { $ticket{'Body'} .= "$_ = $event_info{$_}\n"; }

#
# Convert Ticket and Article data into SOAP data structure
#
my @SOAPTicketData = ();
for my $el (@{$otrs{'TicketFields'}}) {
	if ( $ticket{$el}) {
		for (split (/\n/, $ticket{$el})) {
			$log->debug("TicketData $el = $_"); }
		push @SOAPTicketData, SOAP::Data->name($el => $ticket{$el});
	}
}

my @SOAPArticleData = ();
for my $el (@{$otrs{'ArticleFields'}}) {
	if ( $ticket{$el} ) {
		for (split (/\n/, $ticket{$el})) {
			$log->debug("ArticleData $el = $_"); }
		push @SOAPArticleData, SOAP::Data->name( $el => $ticket{$el} );
	}
}

# Dynamic Fields must be created in OTRS first.
my $DynamicFieldXML;
for ( sort keys %{$ticket{'DynamicField'}} ) {
	if ( $ticket{'DynamicField'}->{$_} ) {
		$log->debug("ArticleData $_ = $ticket{'DynamicField'}->{$_}");
		$DynamicFieldXML .= '<DynamicField><Name><![CDATA['.$_.']]></Name>'
			.'<Value><![CDATA['.$ticket{'DynamicField'}->{$_}.']]></Value></DynamicField>'."\n";
	}
}

if ($opt{'otrs_server'} =~ /^([^:]*)/) {
	my $ip_nbo = inet_aton($1);
	if (!$ip_nbo) { $log->critical("Failed to resolve IP of ".$1); &DoExit(1); }
	$log->info( "OTRS Server is ".$opt{'otrs_server'}." (".inet_ntoa($ip_nbo).")" );
}

my $soap_op = $otrs{'Operation'}; $log->info("SOAP $soap_op at ".$otrs{'URL'});
my $soap_obj = SOAP::Lite->uri($otrs{'NameSpace'})->proxy($otrs{'URL'})->$soap_op(
	SOAP::Data->name('UserLogin')->value($otrs{'UserLogin'}),
    	SOAP::Data->name('Password')->value($otrs{'Password'}),
    	SOAP::Data->name('TicketID')->value($otrs{'TicketID'}),
    	SOAP::Data->name('TicketNumber')->value($otrs{'TicketNumber'}),
	SOAP::Data->name('Ticket' => \SOAP::Data->value(@SOAPTicketData)),
	SOAP::Data->name('Article' => \SOAP::Data->value(@SOAPArticleData)),
	SOAP::Data->type('xml'=> $DynamicFieldXML),
);

if ( $soap_obj->fault ) { $log->critical($soap_obj->faultcode.": ".$soap_obj->faultstring); &DoExit(1); }

$log->info("SOAP transaction successful");

# get the XML response part from the SOAP message
my $XMLResponse = $soap_obj->context()->transport()->proxy()->http_response()->content();

# deserialize response (convert it into a perl structure)
my $Deserialized = eval { SOAP::Deserializer->deserialize($XMLResponse); };

# remove all the headers and other not needed parts of the SOAP message
my $Body = $Deserialized->body();

# check if ticket was created or updated
my $Response = $Body->{'TicketCreateResponse'} ? 
	'TicketCreateResponse' : 'TicketUpdateResponse';

if (defined $Body->{$Response}->{Error}) {
	$log->error("Error found in $Response");
	$log->error($Body->{$Response}->{Error}->{ErrorCode}." = ".$Body->{$Response}->{Error}->{ErrorMessage});
	&DoExit(1);
}

$TicketID = $Body->{$Response}->{TicketID};
$TicketNumber = $Body->{$Response}->{TicketNumber};
$ArticleID = $Body->{$Response}->{ArticleID};

my $ticket_sum = "TicketID $TicketID (TicketNumber $TicketNumber, ArticleID $ArticleID)";

if ($Response eq 'TicketUpdateResponse') { $log->info("Updated $ticket_sum"); }
else {
	$log->info("Created $ticket_sum");
	$log->info("Adding TicketID $TicketID and ProblemID $opt{'problem_id'} to $dbname");
	my $sth = $dbh->prepare("INSERT INTO $dbtable VALUES ( ?, ?, ? )");
	$sth->execute($opt{'problem_id'}, $TicketID, $TicketNumber);
}

&DoExit(0);

sub DoExit {
	my ($err) = @_;
	$log->info("END of $0 v$VERSION script");
	exit $err;
}

