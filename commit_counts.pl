#!/usr/bin/perl

# Generate lists of commit counts for each group member

use strict;
use v5.14;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use Webperl::Utils qw(path_join);
use Text::Sprintf::Named qw(named_sprintf);
use REST::Client;
use JSON;
use Cwd;
use Data::Dumper;

my $cmdfmt = '/usr/bin/git --bare shortlog -ens --since="%(since)s"  --until="%(until)s" --date=local --all';


## @method void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: commit_counts.pl <course> <path> <base> <since> <until>\n";
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


sub fetch_commit_counts {
    my $path   = shift;
    my $base   = shift;
    my $team   = shift;
    my $start  = shift;
    my $finish = shift;

    my $gitdir = path_join($path, $base."_".$team.".git");
    my $pwd = getcwd;

    chdir($gitdir)
        or die "Unable to change to '$gitdir': $!\n";

    my $cmd = named_sprintf($cmdfmt, { "since" => $start, "until" => $finish });

    my $result = `$cmd`;

    print "$team:\n".$result."\n";
}


my $udataconfig = Webperl::ConfigMicro -> new("config/userdata.cfg")
    or die "Error: Unable to load userdata configuration: $!\n";

# Turn on autoflushing
$| = 1;

my $course = shift @ARGV or arg_error("No course specified.");
my $path   = shift @ARGV or arg_error("No path specified.");
my $base   = shift @ARGV or arg_error("No project base name specified.");
my $start  = shift @ARGV or arg_error("No start time specified.");
my $finish = shift @ARGV or arg_error("No end time specified.");

my $rest = REST::Client -> new({ host => $udataconfig -> {"API"} -> {"url"} })
    or die "Failed to create REST Client\n";
$rest -> addHeader("Private-Token", $udataconfig -> {"API"} -> {"token"});

# Fetch the group data from the userdata system
my $groupdata = fetch_group_data($rest, $course)
    or die "Unable to open group file: $!\n";

foreach my $group (@{$groupdata}) {
    fetch_commit_counts($path, $base, $group -> {"name"}, $start, $finish);
}
