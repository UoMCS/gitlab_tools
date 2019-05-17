#!/usr/bin/perl

# Set up webhooks for jenkins integration

use strict;
use v5.12;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use Webperl::Utils qw(load_file);
use GitLab::API::Basic;
use Data::Dumper;
use Text::Sprintf::Named qw(named_sprintf);
use JSON;

our @hook_templates = (
    'http://ci.cs.manchester.ac.uk/jenkins/git/notifyCommit?url=ssh://gitlab@gitlab.cs.man.ac.uk:22222/%(fork)s.git',
    'https://ci.cs.manchester.ac.uk/commitstore/rest/api/push'
    );


## @method $ has_hook($api, $projectid, $url)
# Determine whether the specified hook URL has already been set for this project.
#
# @param api       A reference to a GitLab::API::Basic object to call the API through
# @param projectid The ID of the project to check
# @param url       The URL of the hook to look for
# @return true if the hook has been set, false otherwise
sub has_hook {
    my $api       = shift;
    my $projectid = shift;
    my $url       = shift;

    my $json = $api -> {"api"} -> call("/projects/:id/hooks", "GET", { id => $projectid });
    die "Project hook lookup failed: ".$api -> {"api"} -> errstr()."\n"
        if(!$json);

    return 0 if(!scalar(@{$json}));

    # check each hook looking for amtching URLs
    foreach my $hook (@{$json}) {
        return 1 if(lc($hook -> {"url"}) eq lc($url));
    }

    return 0;
}


## @method void add_hook($api, $projectid, $url)
# Add a push hook to the specified project. This will die on error.
#
# @param api       A reference to a GitLab::API::Basic object to call the API through
# @param projectid The ID of the project to add the hook to
# @param url       The URL of the hook to add#
sub add_hook {
    my $api       = shift;
    my $projectid = shift;
    my $url       = shift;

    print "Adding hook to project $projectid, url = $url\n";

    my $json = $api -> {"api"} -> call("/projects/:id/hooks",
                                        "POST",
                                        {
                                            id => $projectid,
                                            url => $url,
                                            push_events => JSON::true,
                                            tag_push_events => JSON::true,
                                            merge_requests_events => JSON::true,
                                            enable_ssl_verification => JSON::true,
                                        });
    die "Hook creation failed: ".$api -> {"api"} -> errstr()."\n".Dumper($json)."\n"
        unless($json && $json -> {"id"});
}


## @method void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: add_hooks.pl <logfile>...\n";
}


## @method void process_log($api, $file)
# Search through the specified log file to collect the fork IDs, and
# then go through the list of IDs and add hooks.
#
# @param api      A refrence to a GitLab::API::Utils object.
# @param file     The name of a log file to load the fork IDs from.
sub process_log {
    my $api      = shift;
    my $file     = shift;

    my $logdata = load_file($file)
        or die "Unable to load log file: $!\n";

    my %forks = $logdata =~ /^Fork: ([^:]+): (\d+)$/mg;

    foreach my $name (sort keys(%forks)) {

        foreach my $hook (@hook_templates) {
            my $url = named_sprintf($hook, { fork => $name });

            add_hook($api, $forks{$name}, $url)
                unless(has_hook($api, $forks{$name}, $url));
        }
    }
}


my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

# Turn on autoflushing
$| = 1;

arg_error("No log files specified") unless(scalar(@ARGV));

my $api = GitLab::API::Basic -> new(url   => $config -> {"gitlab"} -> {"url"},
                                    token => $config -> {"gitlab"} -> {"token"});

foreach my $file (@ARGV) {
    process_log($api, $file);
}