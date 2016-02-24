#!/usr/bin/perl

use strict;
use v5.12;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use GitLab::API::Basic;
use Data::Dumper;

sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: lookup.pl <username> <project>\n";
}

my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $username = shift @ARGV or arg_error("No username specified.");
my $project  = shift @ARGV or arg_error("No project name specified.");

my $api = GitLab::API::Basic -> new(url   => $config -> {"gitlab"} -> {"url"},
                                    token => $config -> {"gitlab"} -> {"token"});
$api -> sudo($username);

my $result = $api -> call("/projects", "GET", { "search" => $project });
print Dumper($result);
