#!/usr/bin/env perl

# A script to mark pushes in gitlab repositories. This can be used
# to tag push commits or to analyse push patterns.

use strict;
use v5.12;
use lib qw(/home/chris/gitlabwork/GitLab-API-Basic/lib);
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

    die "Error: $message\nUsage: mark_pushes.pl <logfile>...\n";
}


## @fn void mark_pushes($api, $projectid)
# Look up the pushes recorded in the event log for the specified project, and
# mark the pushes in the repository with tags.
#
# @param api       A reference to a GitLab::API::Utils object.
# @param projectid The ID of the project to mark the pushes.
sub mark_pushes {
    my $api       = shift;
    my $projectid = shift;

    # Fetch the list of push events
    my $res = $api -> {"api"} -> call("/projects/:id/events", "GET", { id    => $projectid,
                                                                       action => "pushed"} )
        or die "Error: ".$api -> {"api"} -> errstr()."\n";

    # Go through the list of pushes
    foreach my $event (@{$res}) {

        # Find the last commit for this push
        my $lastcommit = @{$event -> {"data"} -> {"commits"}}[-1];

        # Mark it
        print "Marking ".$lastcommit -> {"id"}." = ".$lastcommit -> {"timestamp"}."\n";
        $res = $api -> {"api"} -> call("/projects/:id/repository/tags", "POST", { id       => $projectid,
                                                                                  tag_name => 'SELA/'.$lastcommit -> {"id"},
                                                                                  ref      => $lastcommit -> {"id"} })
            or die "Error: ".$api -> {"api"} -> errstr()."\n";
    }
}


## @method void process_log($api, $file)
# Go through the specified log file looking for fork IDs, and
#
# @param api  A refrence to a GitLab::API::Utils object.
# @param file The name of a log file to load the fork IDs from.
sub process_log {
    my $api  = shift;
    my $file = shift;

    my $logdata = load_file($file)
        or die "Unable to load log file: $!\n";

    my @ids = $logdata =~ /^Fork: [^:]+: (\d+)$/mg;

    foreach my $id (@ids) {
        print "Marking pushes for project $id... ";
        mark_pushes($api, $id);
    }
}


my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $api = GitLab::API::Utils -> new(url      => $config -> {"gitlab"} -> {"url"},
                                    token    => $config -> {"gitlab"} -> {"token"},
                                    autosudo => 1);
# Turn on autoflushing
$| = 1;

my $logfile = shift @ARGV or arg_error("No logfile specified.");

process_log($api, $logfile);
