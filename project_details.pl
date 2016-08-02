#!/usr/bin/perl

use strict;
use v5.12;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use GitLab::API::Utils;
use Data::Dumper;

sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: project_details.pl <project id>\n";
}

my $projectid = $ARGV[0]
    or arg_error("No project id specified");

my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $api = GitLab::API::Utils -> new(url      => $config -> {"gitlab"} -> {"url"},
                                    token    => $config -> {"gitlab"} -> {"token"},
                                    autosudo => 1);

my $project = $api -> {"api"} -> call("/projects/:id", "GET", { id => $projectid } )
	or die "Error: ".$api -> {"api"} -> errstr()."\n";
print Dumper($project);
