#!/usr/bin/perl

use strict;
use v5.12;
use lib qw(/home/chris/gitlabwork/GitLab-API-Basic/lib);
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use GitLab::API::Utils;
use Data::Dumper;

sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: lookup.pl <username> <project>\n";
}

my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $api = GitLab::API::Utils -> new(url      => $config -> {"gitlab"} -> {"url"},
                                    token    => $config -> {"gitlab"} -> {"token"},
                                    autosudo => 1);

my $project = $api -> {"api"} -> call("/projects/:id", "GET" , { id => 5478 });
print Dumper($project);

my $issues = $api -> fetch_issues(4) #(5478)
    or die "Error: ".$api -> errstr()."\n";

print "Issues: ".Dumper($issues)."\n";
