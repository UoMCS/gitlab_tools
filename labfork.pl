#!/usr/bin/perl

# Deep fork a GitLab project. This will perform a series of deep forks
# to a given namespace, setting up the user access to the forked projects.
#
# This fetches group information from the UserData API, and forks the
# specified project once for each group, adding the group members to the
# forked projects as it goes.
#

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

    die "Error: $message\nUsage: labfork.pl <sourceID> <course> <namespace> <projbase>\n";
}


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

    print "DEBUG: Generating group lists...\n";

    my $groups = { };
    my $failures = [];
    foreach my $group (@{$groupdata}) {
        print "DEBUG: Got group ".$group -> {"name"}." with ".scalar(@{$group -> {"users"}})." members\n";

        push(@{$group -> {"users"}}, { "email"    => named_sprintf($settings -> {"groups"} -> {"email_format"}, { "group" => $group -> {"name"} }),
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
                print "failed.\n";
            }
        }
    }

    return ($groups, $failures);
}


sub deep_clone {
    my $api       = shift;
    my $sourceid  = shift;
    my $namespace = shift;
    my $projname  = shift;
    my $userids   = shift;

    print "DEBUG: Doing deep fork of $sourceid... ";
    # Do the actual fork into the admin user space
    my $forkid = $api -> deep_fork($sourceid)
        or die "Error: ".$api -> errstr()."\n";

    print "Done.\nDEBUG: Doing rename of $forkid as $projname... ";
    # Rename it so it can be moved sanely
    $api -> rename_project($forkid, $projname)
        or die $api -> errstr()."\n";

    print "Done.\nDEBUG: Moving $forkid into namespace $namespace... ";
    # And move it into the target namespace
    $api -> move_project($forkid, $namespace)
        or die $api -> errstr()."\n";

    print "Done.\nDEBUG: Syncing milestones, issues, and labels.... ";
    $api -> sync_issues($sourceid, $forkid, 1)
        or die $api -> errstr()."\n";

    print "Done.\nFork: $namespace/$projname: $forkid\nDEBUG: Adding users...";
    if(scalar(@{$userids})) {
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
my ($grouphash, $failures) = generate_group_lists($api, $groupdata, $config);
print "WARN: One or more user lookups failed:\n\t".join("\n\t", @{$failures})."\nIgnoring failed users.\n"
    if(scalar(@{$failures}));

foreach my $group (sort keys(%{$grouphash})) {
    deep_clone($api, $sourceid, $namespace, $projbase."_".$group, $grouphash -> {$group});
}