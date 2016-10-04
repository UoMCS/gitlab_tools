#!/usr/bin/perl

use strict;
use v5.12;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use Webperl::Utils qw(load_file);
use Text::Sprintf::Named qw(named_sprintf);
use GitLab::API::Utils;
use Data::Dumper;

sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: setjenkinsusers.pl <forkfile> <groupbase>\n";
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


## @fn void add_jenkins_user($group, $fork, $api, $settings, $groupbase)
# Add the jenkins user for the specified group to the fork.
#
# @param group     The name of the group that owns the fork
# @param fork      The gitlab ID of the fork
# @param api       A reference to a GitLab::API::Utils object
# @param settings  A reference to the global settings object
# @param groupbase A string to prepend to the group name (will have '_'
#                  added to the end) when generating the jenkins user
#                  email address.
sub add_jenkins_user {
    my $group     = shift;
    my $fork      = shift;
    my $api       = shift;
    my $settings  = shift;
    my $groupbase = shift;

    my $email = named_sprintf($settings -> {"groups"} -> {"email_format"}, { "group" => $groupbase."_".$group });

    print "DEBUG: Looking up '$email' in '$group'... ";
    my $res = $api -> {"api"} -> call("/users", "GET", { search => $email });
    if($res && scalar(@{$res})) {
        print "uid: ".$res -> [0] -> {"id"}."\n";
        print "DEBUG: Adding user as reporter to fork $fork... ";

        $api -> add_users($fork, $res -> [0] -> {"id"}, 30)
            or die $api -> errstr()."\n";

        print "Done.\n";
    } else {
        print "failed.\n";
    }
}

my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $forkfile  = shift @ARGV or arg_error("No fork file specified.");
my $groupbase = shift @ARGV or arg_error("No base group name specified.");

my $api = GitLab::API::Utils -> new(url   => $config -> {"gitlab"} -> {"url"},
                                    token => $config -> {"gitlab"} -> {"token"});

# Pull the group/fork ID relations
my $forks = process_log($forkfile);
die "No group/fork relations defined in specified group file.\n"
    unless($forks && scalar(keys(%{$forks})));

# If groups have been specified, go through and set just those
foreach my $group (keys(%{$forks})) {
    print "Adding jenkins user for group $group...\n";
    add_jenkins_user($group, $forks -> {$group}, $api, $config, $groupbase);
}
