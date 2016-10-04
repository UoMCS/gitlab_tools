#!/usr/bin/perl

use strict;
use v5.12;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use GitLab::API::Utils;
use Data::Dumper;

sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: deepfork.pl <sourceID> <namespace> <projectname> [<user email>, ...]\n";
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

my $sourceid  = shift @ARGV or arg_error("No sourceID specified.");
my $namespace = shift @ARGV or arg_error("No namespace specified.");
my $projname  = shift @ARGV or arg_error("No project name specified.");
my @users     = @ARGV;

my $api = GitLab::API::Utils -> new(url   => $config -> {"gitlab"} -> {"url"},
                                    token => $config -> {"gitlab"} -> {"token"});

# Convert the email address of users to internal IDs. This is a vital step
# where failures should kill the script before anything is done.
my $userids  = $api -> lookup_users(\@users);

deep_clone($api, $sourceid, $namespace, $projname, $userids);