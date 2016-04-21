#!/usr/bin/perl

use strict;
use v5.12;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use Webperl::Utils qw(load_file);
use GitLab::API::Utils;
use Data::Dumper;

sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: setbulkaccess.pl <level> <groupfile> [group...]\n";
}


## @method void process_log($file)
# Search through the specified log file to collect the groups and the fork
# associated with each group.
#
# @param file The name of the log file to process.
# @return A reference to a hash of group names and fork IDs.
sub process_log {
    my $file  = shift;

    my $logdata = load_file($file)
        or die "Unable to load log file: $!\n";

    my %forks = $logdata =~ /^Fork: [^:]+_(\w+): (\d+)$/mg;
    return \%forks;
}


## @method void set_permission($api, $levelid, $projid)
# Set all the users associated with the project to the specified level. This will
# override the permissions settings for the users, but it *will not* add or remove
# them
#
# @param api     A reference to an API object to issue queries through.
# @param levelid The ID of the access level to set users to. See GitLab::API::Basic
# @param projid  The ID of the project to set the user access in.
sub set_permission {
    my $api     = shift;
    my $levelid = shift;
    my $projid  = shift;

    # first fetch a list of all users on the specified fork
    my $users = $api -> {"api"} -> call("/projects/:id/members", "GET", { id => $projid } )
        or die "Error: ".$api -> {"api"} -> errstr()."\n";

    # now set each user's permission to the level specified
    foreach my $user (@{$users}) {
        print "Setting ".$user -> {"name"}." to permission $levelid on $projid...\n";
        my $res = $api -> {"api"} -> call("/projects/:id/members/:user_id", "PUT", { id           => $projid,
                                                                                     user_id      => $user -> {"id"},
                                                                                     access_level => $levelid } )
            or die "Unable to set permissions for ".$user -> {"name"}." on fork $projid: ".$api -> {"api"} -> errstr()."\n";
    }
}


my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $level     = shift @ARGV or arg_error("No access level specified.");
my $groupfile = shift @ARGV or arg_error("No groupfile specified.");
my @groups    = @ARGV;

my $api = GitLab::API::Utils -> new(url   => $config -> {"gitlab"} -> {"url"},
                                    token => $config -> {"gitlab"} -> {"token"});

# convert the level
my $levelid = $api -> {"api"} -> {"access_levels"} -> {$level}
    or die "The specified level is not valid. Valid levels are: ".join(", ", keys(%{$api -> {"api"} -> {"access_levels"}}))."\n";

# Pull the group/fork ID relations
my $forks = process_log($groupfile);
die "No group/fork relations defined in specified group file.\n"
    unless($forks && scalar(keys(%{$forks})));

# If groups have been specified, go through and set just those
if(scalar(@groups)) {
    foreach my $group (@groups) {
        if($forks -> {$group}) {
            set_permission($api, $levelid, $forks -> {$group});
        } else {
            warn "Attempt to set permissions for non-existent group '$group'\n";
        }
    }

# No groups specified, so do all of them
} else {
    foreach my $group (keys(%{$forks})) {
        set_permission($api, $levelid, $forks -> {$group});
    }
}