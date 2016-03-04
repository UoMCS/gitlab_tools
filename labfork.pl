#!/usr/bin/perl

# Deep fork a GitLab project. This will perform a series of deep forks
# to a given namespace, setting up the user access to the forked projects.
#
# The groupfile should be a csv file, the first column is the user email
# address, the second column is the group:
#
# <email>,<group>
#
# group names must be alphanumerics only.

use strict;
use v5.12;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use GitLab::API::Utils;
use Data::Dumper;


## @method void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: labfork.pl <sourceID> <namespace> <projbase> <groupfile>\n";
}


## @fn $ load_file($name)
# Load the contents of the specified file into memory. This will attempt to
# open the specified file and read the contents into a string. This should be
# used for all file reads whenever possible to ensure there are no internal
# problems with UTF-8 encoding screwups.
#
# @param name The name of the file to load into memory.
# @return The string containing the file contents, or undef on error. If this
#         returns undef, $! should contain the reason why.
sub load_file {
    my $name = shift;

    if(open(INFILE, "<:utf8", $name)) {
        undef $/;
        my $lines = <INFILE>;
        $/ = "\n";
        close(INFILE)
            or return undef;

        return $lines;
    }
    return undef;
}


sub generate_group_lists {
    my $api       = shift;
    my $groupdata = shift;

    print "DEBUG: Generating group lists...\n";

    my $groups = { };
    my @rows = split(/^/, $groupdata);
    my $failures = [];
    foreach my $row (@rows) {
        chomp($row);

        my ($email, $uomid, $group) = $row =~ /^([^,]+),(\d+),(\w+)$/;
        die "Unable to parse email or group from row\n'$row'\n\tEmail: ".($email || "not parsed")."\n\tGroup: ".($group || "not parsed")."\n"
            unless($email && $group);

        print "DEBUG: Looking up $email in $group... ";
        my $res = $api -> {"api"} -> call("/users", "GET", { search => $email });
        if($res && scalar(@{$res})) {
            push(@{$groups -> {uc($group)}}, $res -> [0] -> {"id"});
            print "uid: ".$res -> [0] -> {"id"}."\n";
        } else {
            push(@{$failures}, $row);
            print "failed.\n";
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

# Turn on autoflushing
$| = 1;

my $sourceid  = shift @ARGV or arg_error("No sourceID specified.");
my $namespace = shift @ARGV or arg_error("No namespace specified.");
my $projbase  = shift @ARGV or arg_error("No project base name specified.");
my $groupfile = shift @ARGV or arg_error("No group file specified.");

my $api = GitLab::API::Utils -> new(url   => $config -> {"gitlab"} -> {"url"},
                                    token => $config -> {"gitlab"} -> {"token"});

my $groupdata = load_file($groupfile)
    or die "Unable to open group file: $!\n";

my ($grouphash, $failures) = generate_group_lists($api, $groupdata);
print "WARN: One or more user lookups failed:\n\t".join("\n\t", @{$failures})."\nIgnoring failed users.\n"
    if(scalar(@{$failures}));

foreach my $group (keys(%{$grouphash})) {
    deep_clone($api, $sourceid, $namespace, $projbase."_".$group, $grouphash -> {$group});
}