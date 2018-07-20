#!/usr/bin/env perl

# A script to mark pushes in gitlab repositories. This can be used
# to tag push commits or to analyse push patterns.
#
# This script uses the GitLab event list to find the pushes in a
# project (unlike find_pushes.pl, which uses object database times)
#
# Expected invocation:
#
# ./mark_pushes.pl <fork log file> 2>&1 | tee <output log>

use strict;
use v5.12;
use lib qw(/home/chris/gitlabwork/GitLab-API-Basic/lib);
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use Webperl::Utils qw(load_file);
use GitLab::API::Utils;
use Data::Dumper;

# Global result accumulator.
my @results;


## @fn void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: mark_pushes.pl <logfile>...\n";
}


## @fn void copy_marked_commits($tags, $marked)
# Given a list of tags, determine which ones correspond to commits marked as the
# last commit before a push, and copy them into the hash of marked commits.
#
# @param tags A reference to an array of tag hashes.
# @param marked A reference to the marked commit hash.
sub copy_marked_commits {
    my $tags   = shift;
    my $marked = shift;

    foreach my $tag (@{$tags}) {
        # Only look at SELA tags, we don't care about user's tags
        next unless($tag -> {"name"} =~ /^SELA/);

        # Pull the commit out of the tag and store it as marked
        my ($sha1) = $tag -> {"name"} =~ m|^SELA/(.*?)$|;
        $marked -> {$sha1} = 1;
    }
}

sub get_marked_commits {
    my $api       = shift;
    my $projectid = shift;
    my $marked = {};

    my $res = $api -> {"api"} -> call("/projects/:id/repository/tags", "GET", { id => $projectid, });
    copy_marked_commits($res, $marked);

    while($api -> {"api"} -> next_page()) {
        print "Fetching next page of tags.\n";

        $res = $api -> {"api"} -> call_url("GET", $api -> {"api"} -> next_page())
            or die "Error: ".$api -> {"api"} -> errstr()."\n";

        copy_marked_commits($res, $marked);
    }

    return $marked;
}


sub copy_push_events {
    my $source = shift;
    my $dest   = shift;

    foreach my $event (@{$source}) {
        # Skip events created by root (probably previous tagging events)
        next if($event -> {"author_username"} eq "root");

        # SKip events with no commits
        next unless(scalar(@{$event -> {"data"} -> {"commits"}}));

        push(@{$dest}, $event);
    }
}


sub get_push_events {
    my $api       = shift;
    my $projectid = shift;
    my $group     = shift;

    my @events;

    # Fetch the list of push events
    my $res = $api -> {"api"} -> call("/projects/:id/events", "GET", { id    => $projectid,
                                                                       action => "pushed" } )
        or die "Error: ".$api -> {"api"} -> errstr()."\n";

    copy_push_events($res, \@events);


    while($api -> {"api"} -> next_page()) {
        print "Fetching next page of events.\n";

        $res = $api -> {"api"} -> call_url("GET", $api -> {"api"} -> next_page())
            or die "Error: ".$api -> {"api"} -> errstr()."\n";

        copy_push_events($res, \@events);
    }

    return \@events;
}

#
sub create_tags {
    my $api       = shift;
    my $projectid = shift;
    my $res       = shift;
    my $group     = shift;

    # Find out which tags have already
    my $marked = get_marked_commits($api, $projectid);

    print "Got ".scalar(@{$res})." push events.\n";
    print "Already marked ".scalar(keys(%{$marked}))." events.\n";
    sleep(3);

    # Go through the list of pushes
    foreach my $event (@{$res}) {
        # Can't mark commits if there are no commits!
        next unless(scalar(@{$event -> {"data"} -> {"commits"}}));

        # Find the last commit for this push
        my $lastcommit = @{$event -> {"data"} -> {"commits"}}[-1];

        # Has this commit already been marked? If so, just record that fact
        if($marked -> {$lastcommit -> {"id"}}) {
            print "Skipping already marked ".$lastcommit -> {"id"}."\n";

            # Only push the first instance of the tag
            if($marked -> {$lastcommit -> {"id"}} == 1) {
                push(@results, { cohort   => 'na',
                                 team     => $group,
                                 exercise => 1,
                                 tag      => 'SELA/'.$lastcommit -> {"id"},
                                 commit   => $lastcommit -> {"id"},
                                 time     => $lastcommit -> {"timestamp"}});
            }

            ++$marked -> {$lastcommit -> {"id"}};

        # Hasn't been marked, so tag it
        } else {
            print "Marking ".$lastcommit -> {"id"}." = ".$lastcommit -> {"timestamp"}."\nTag: SELA/".$lastcommit -> {"id"}."\n";
            $res = $api -> {"api"} -> call("/projects/:id/repository/tags", "POST", { id       => $projectid,
                                                                                      tag_name => 'SELA/'.$lastcommit -> {"id"},
                                                                                      ref      => $lastcommit -> {"id"} })
                or warn "Tag failed: ".$api -> {"api"} -> errstr()."\n";

            # If the tag creation was successful, record it
            if($res) {
                $marked -> {$lastcommit -> {"id"}} = 1;

                push(@results, { cohort   => 'na',
                                 team     => $group,
                                 exercise => 1,
                                 tag      => 'SELA/'.$lastcommit -> {"id"},
                                 commit   => $lastcommit -> {"id"},
                                 time     => $lastcommit -> {"timestamp"}});
            }
        }
    }

    print "Marked status: ".Dumper($marked)."\n";
}


## @fn void mark_pushes($api, $projectid, $group)
# Look up the pushes recorded in the event log for the specified project, and
# mark the pushes in the repository with tags.
#
# @param api       A reference to a GitLab::API::Utils object.
# @param projectid The ID of the project to mark the pushes.
#
sub mark_pushes {
    my $api       = shift;
    my $projectid = shift;
    my $group     = shift;

    # Fetch all the push events set for the project, and then tag the pushes
    my $events = get_push_events($api, $projectid, $group);
    create_tags($api, $projectid, $events, $group);
}


## @fn void process_log($api, $file)
# Go through the specified log file looking for fork IDs, and for each fork
# mark all the pushes that have been made to that fork with SELA tags.
#
# @param api  A refrence to a GitLab::API::Utils object.
# @param file The name of a log file to load the fork IDs from.
sub process_log {
    my $api  = shift;
    my $file = shift;

    my $logdata = load_file($file)
        or die "Unable to load log file: $!\n";

    my %projects = $logdata =~ /^Fork: .*?\/([^:]+): (\d+)$/mg;

    foreach my $group (sort keys(%projects)) {
        print "Marking pushes for group $group - project ".$projects{$group}."...\n";
        mark_pushes($api, $projects{$group}, $group);
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

print "Results:\n";
foreach my $res (@results) {
    print join(",", $res -> {"cohort"},
                    $res -> {"team"},
                    $res -> {"exercise"},
                    $res -> {"tag"},
                    $res -> {"commit"},
                    $res -> {"time"})."\n";
}
