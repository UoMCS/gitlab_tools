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

my $destid = $api -> deep_fork(4)
    or die "Error: ".$api -> errstr()."\n";

warn "Dest: $destid.\n";

$api -> move_project($destid, "testing-group")
    or die "Error: ".$api -> errstr()."\n";

warn "Moved.\n";

$api -> sync_issues(4, $destid, 1)
    or die "Error: ".$api -> errstr()."\n";

print "done.\n";
