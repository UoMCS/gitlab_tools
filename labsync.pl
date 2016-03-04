#!/usr/bin/perl

# Update the issues in deep-forked projects to pick up any new issues
# set in the original project.


use strict;
use v5.12;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use Webperl::Utils qw(load_file);
use GitLab::API::Utils;
use Data::Dumper;


## @method void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: labsync.pl <sourceID> <logfile>...\n";
}


## @method void process_log($api, $sourceid, $file)
# Search through the specified log file to collect the fork IDs, and
# then go through the list of IDs and synchronise the issues with
# the source project.
#
# @param api      A refrence to a GitLab::API::Utils object.
# @param sourceid The ID of the source project to sync issues from.
# @param file     The name of a log file to load the fork IDs from.
sub process_log {
    my $api      = shift;
    my $sourceid = shift;
    my $file     = shift;

    my $logdata = load_file($file)
        or die "Unable to load log file: $!\n";

    my @ids = $logdata =~ /^Fork: [^:]+: (\d+)$/mg;

    foreach my $id (@ids) {
        print "Synchronising issues from $sourceid to $id... ";
        if($api -> sync_issues($sourceid, $id, 1)) {
            print "done.\n";
        } else {
            print "\nERROR: ".$api -> errstr()."\n";
        }
    }
}


my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

# Turn on autoflushing
$| = 1;

my $sourceid = shift @ARGV or arg_error("No sourceID specified.");
arg_error("No log files specified") unless(scalar(@ARGV));

my $api = GitLab::API::Utils -> new(url   => $config -> {"gitlab"} -> {"url"},
                                    token => $config -> {"gitlab"} -> {"token"});

foreach my $file (@ARGV) {
    process_log($api, $sourceid, $file);
}