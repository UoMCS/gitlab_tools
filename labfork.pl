#!/usr/bin/perl

# Deep fork a GitLab project. This will perform a series of deep forks
# to a given namespace, setting up the user access to the forked projects.
#
# This fetches group information from the UserData API, and forks the
# specified project once for each group, adding the group members to the
# forked projects as it goes.
#
# If the optional [json file] argument is provided, it should be the
# filename of a file containing JSON data defining the groups to create
# projects for in the format
# [
#   {
#     "name": "name of the group",
#     "users": [
#                {
#                  "username" : "student username",
#                  "email" : "student email address",
#                },
#                ...
#              ]
#   },
#   ...
# ]

use strict;
use v5.14;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use Webperl::Utils qw(load_file);
use Text::Sprintf::Named qw(named_sprintf);
use GitLab::API::Utils;
use REST::Client;
use JSON;
use Data::Dumper;


## @method void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: labfork.pl <sourceID> <year> <course> <namespace> <projbase> [json file]\n";
}


## @fn $ load_group_data($filename)
# Load the group setup JSON from the specified file. This expects a JSON
# file formatted in a way that matches the output from the userdata API
# GET /courses/{year}/groups/{course} endpoint.
#
# @param filename The name of the file to load the JSON from
# @return A reference to an array of group hashes.
sub load_group_data {
    my $filename = shift;

    my $data = load_file($filename)
        or die "Unable to read file: $!\n";

    my $json = decode_json($data);

    return $json;
}


## @fn $ fetch_group_data($rest, $course)
# Fetch the group data from the UserData API for the specified course.
#
# @param rest   A reference to a REST::Client to issue queries through
# @param course The course to fetch the groups for
# @return A reference to an array of group hashes.
sub fetch_group_data {
    my $rest   = shift;
    my $course = shift;

    my $resp = $rest -> GET("/courses/current/groups/$course");
    my $json = decode_json($resp -> responseContent());

    # Pick up and fall over from errors
    die "Unable to fetch group list from API. Error was:\n".$json -> {"error"} -> {"info"}."\n"
        if(ref($json) eq "HASH" && $json -> {"error"});

    return $json;
}


## @fn @ generate_group_lists($api, $groupdata, $settings)
# Given an array of groups, generate a new hash containing group members by
# gitlab user ID.
#
# @param api       A reference to a GitLab::API::Utils object
# @param groupdata A reference to an array of group hashes as returned by
#                  the fetch_group_data() function.
# @param settings  A reference to the global settings object
# @return An array of two values; the first is a reference to a hash of
#         group member arrays, the second is a reference to an array of
#         user lookup failures.
sub generate_group_lists {
    my $api       = shift;
    my $groupdata = shift;
    my $settings  = shift;
    my $course    = shift;
    my $year      = shift;

    print "DEBUG: Generating group lists...\n";

    my $groups = { };
    my $failures = [];
    foreach my $group (@{$groupdata}) {
        print "DEBUG: Got group ".$group -> {"name"}." with ".scalar(@{$group -> {"users"}})." members\n";

        push(@{$group -> {"users"}}, { "email"    => named_sprintf($settings -> {"groups"} -> {"email_format"}, { group  => $group -> {"name"},
                                                                                                                  course => $course,
                                                                                                                  year   => $year }),
                                       "username" => "User for group ".$group -> {"name"},
                                       "user_id"  => "NA" })
            if($settings -> {"groups"} -> {"autogroup"});

        foreach my $user (@{$group -> {"users"}}) {
            print "DEBUG: Looking up ".$user -> {"email"}." in ".$group -> {"name"}."... ";
            my $res = $api -> {"api"} -> call("/users", "GET", { search => $user -> {"email"} });
            if($res && scalar(@{$res})) {
                push(@{$groups -> {$group -> {"name"}}}, $res -> [0] -> {"id"});
                print "uid: ".$res -> [0] -> {"id"}."\n";
            } else {
                push(@{$failures}, $user -> {"user_id"}.": ".$user -> {"username"}.", ".$user -> {"email"});
                print "failed: ".($res -> {"errstr"} // "no error set")."\n";
            }
        }
    }

    return ($groups, $failures);
}


## @fn void deep_clone($api, $sourceid, $namespace, $projname, $userids, $dryrun)
# Perform a deep clone of a project into a new namespace with a new name, and
# enrol the specified users on the new clone as developers.
#
# @param api       A reference to a gitlab API object
# @param sourceid  The ID of the source project to fork.
# @param namespace The namespace to move the fork into.
# @param userids   A reference to an array of user IDs to add to the fork.
# @param dryrun    If set, do not actually perform any operations, just pretend to.
sub deep_clone {
    my $api       = shift;
    my $sourceid  = shift;
    my $namespace = shift;
    my $projname  = shift;
    my $userids   = shift;
    my $dryrun    = shift;

    print "DEBUG: Doing deep fork of $sourceid... ";
    # Do the actual fork into the admin user space
    my $forkid;

    if($dryrun) {
        $forkid = 12345;
    } else {
        $forkid = $api -> deep_fork($sourceid, "root")
            or die "Error: ".$api -> errstr()."\n";

        sleep(2); # slow things a bit to let server keep up
    }

    print "Done.\nDEBUG: Doing rename of $forkid as $projname... ";
    # Rename it so it can be moved sanely
    unless($dryrun) {
        $api -> rename_project($forkid, $projname)
            or die $api -> errstr()."\n";
    }

    print "Done.\nDEBUG: Moving $forkid into namespace $namespace... ";
    # And move it into the target namespace
    unless($dryrun) {
        $api -> move_project($forkid, $namespace)
            or die $api -> errstr()."\n";
    }

    print "Done.\nDEBUG: Syncing milestones, issues, and labels.... ";
    unless($dryrun) {
        $api -> sync_issues($sourceid, $forkid, 1)
            or die $api -> errstr()."\n";
    }

    print "Done.\nFork: $namespace/$projname: $forkid\nDEBUG: Adding users...";
    if(!$dryrun && scalar(@{$userids})) {
        my $userhash = {};
        foreach my $userid (@{$userids}) {
            $userhash -> {$userid} = $api -> {"api"} -> {"access_levels"} -> {"developer"};
        }

        $api -> set_users($forkid, $userhash)
            or die $api -> errstr()."\n";
    }
    print "Done.\n"
}


my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $udataconfig = Webperl::ConfigMicro -> new("config/userdata.cfg")
    or die "Error: Unable to load userdata configuration: $!\n";

# Turn on autoflushing
$| = 1;

my $sourceid  = shift @ARGV or arg_error("No sourceID specified.");
my $year      = shift @ARGV or arg_error("No year specified.");
my $course    = shift @ARGV or arg_error("No course specified.");
my $namespace = shift @ARGV or arg_error("No namespace specified.");
my $projbase  = shift @ARGV or arg_error("No project base name specified.");
my $jsonfile  = shift @ARGV;

my $api = GitLab::API::Utils -> new(url   => $config -> {"gitlab"} -> {"url"},
                                    token => $config -> {"gitlab"} -> {"token"});

my $rest = REST::Client -> new({ host => $udataconfig -> {"API"} -> {"url"} })
    or die "Failed to create REST Client\n";
$rest -> addHeader("Private-Token", $udataconfig -> {"API"} -> {"token"});

print "Autogroup is ".($config -> {"groups"} -> {"autogroup"} ? "on" : "off").". Press return to continue.";
my $conf = <STDIN>;

# Fetch the group data from the userdata system
my $groupdata;
if($jsonfile) {
    $groupdata = load_group_data($jsonfile);
} else {
    $groupdata = fetch_group_data($rest, $course)
}

# Now convert the users in the groups into gitlab users
my ($grouphash, $failures) = generate_group_lists($api, $groupdata, $config, $course, $year);
print "WARN: One or more user lookups failed:\n\t".join("\n\t", @{$failures})."\nIgnoring failed users.\n"
    if(scalar(@{$failures}));

foreach my $group (sort keys(%{$grouphash})) {
    deep_clone($api, $sourceid, $namespace, $projbase."_".$group, $grouphash -> {$group}, 0);
}