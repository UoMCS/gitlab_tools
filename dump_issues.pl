#!/usr/bin/perl

# A script to populate group assignments in the userdata system via the API.
# Given a course name and group file, this will try to add the users to
# the group in the course for the current year.
#
# The team file should be a CSV, with headers on the first line. Required
# columns are specified in the config file as
#
# [Teams]
# teamfield = team
# idfield   = person_id
#
use strict;
use v5.12;
use lib qw(/var/www/webperl);

use FindBin;             # Work out where we are
my $scriptpath;
BEGIN {
    $ENV{"PATH"} = "/bin:/usr/bin"; # safe path.

    # $FindBin::Bin is tainted by default, so we may need to fix that
    # NOTE: This may be a potential security risk, but the chances
    # are honestly pretty low...
    if ($FindBin::Bin =~ /(.*)/) {
        $scriptpath = $1;
    }
}

use Webperl::ConfigMicro;
use Webperl::Utils qw(load_file save_file);
use GitLab::API::Utils;
use Text::Sprintf::Named qw(named_sprintf);
use DateTime;
use JSON;
use Data::Dumper;

## @fn void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: dump_issues.pl <teamfiler> <teamfile> <outputfile>\n";
}


## @fn $ get_issue_data($api, $projid)
# Given a project ID, fetch the issues list for the project, including notes.
#
# @param api A reference to a GitLab::API::Utils object to issue queries through.
# @param projid The ID of the project to fetch the data for.
# @return A reference to a hash containing the project name, and the issues array.
sub get_issue_data {
    my $api    = shift;
    my $projid = shift;
    my $projdata = {};

    # Get th eproject information first
    my $res = $api -> {"api"} -> call("/projects/:id", "GET", { id => $projid });
    die "Project lookup for '$projid' failed: ".$api -> {"api"} -> errstr()."\n"
        if(!$res);

    $projdata -> {"name"} = $res -> {'path_with_namespace'};

    my $issues = $api -> fetch_issues($projid)
        or die "Unable to fetch issues for ".$projdata -> {"name"}.": ".$api -> errstr();

    # Resort issues by iid
    my @sorted = sort { $a -> {"iid"} <=> $b -> {"iid"} } @{$issues};

    $projdata -> {"issues"} = \@sorted;

    return $projdata;
}


## @fn $ find_close($notes)
# Locate the last "status changed to closed" note in the provided array of
# notes, and return the timestamp and author of the note if successful.
#
# @param notes A reference to an array of notes.
# @return The timestamp of the close, and the name of the user who closed the
#         issue, if a close note is found, empty strings otherwise.
sub find_close {
    my $notes   = shift;
    my @revlist = reverse(@{$notes});

    foreach my $note (@revlist) {
        return ($note -> {"created_at"}, $note -> {"author"} -> {"name"})
            if($note -> {"body"} eq "Status changed to closed");
    }

    return ("", "");
}


## @fn $ build_issue_header()
# Generate the header line to include at the start of the CSV file.
#
# @return A string containing the header line.
sub build_issue_header {
    return '"repo name","issue id","issue title","created","created by","state","assigned to","closed at","closed by"'."\n";
}


## @fn $ build_issue_data($projdata)
# Given the data for a project, generate a string containing the CSV data
# describing all the issues defined for the project.
#
# @param projdata A reference to a hash containing project data as generated
#                 by get_issue_data()
# @return A string containing the CSV data for the project's issues.
sub build_issue_data {
    my $projdata = shift;

    my $result = "";
    foreach my $issue (@{$projdata -> {"issues"}}) {
        my ($closedat, $closedby) = ("", "");

        # Locate the closed information if it is closed.
        ($closedat, $closedby) = find_close($issue -> {"notes"})
            if($issue -> {"state"} eq "closed");

        my @fields = ( $projdata -> {"name"},
                       $issue -> {"iid"} ,
                       $issue -> {"title"},
                       $issue -> {"created_at"},
                       $issue -> {"author"} -> {"name"},
                       $issue -> {"state"},
                       $issue -> {"assignee"} ? $issue -> {"assignee"} -> {"name"} : "",
                       $closedat,
                       $closedby
            );

        $result .= '"'.join('","', @fields)."\"\n";
    }

    return $result;
}


my $start = DateTime -> now();

my $config = Webperl::ConfigMicro -> new(path_join($scriptpath, "config", "gitlab.cfg"))
    or die "Error: Unable to load configuration: $!\n";

my $filter   = shift @ARGV or arg_error("No team filter specified.");
my $teamfile = shift @ARGV or arg_error("No team file specified.");
my $outname  = shift @ARGV or arg_error("No output file specified.");

my $api = GitLab::API::Utils -> new(url   => $config -> {"gitlab"} -> {"url"},
                                    token => $config -> {"gitlab"} -> {"token"});

my $logdata = load_file($teamfile)
    or die "Unable to load log file: $!\n";

my @ids = $logdata =~ /^Fork: [^:]+_$filter: (\d+)$/mg;

my $outfile = named_sprintf($outname, { "timestamp" => $start -> strftime("%FT%T") });

my $outdata = build_issue_header();
foreach my $id (@ids) {
    print "Processing project $id...\n";
    my $projdata = get_issue_data($api, $id);
    $outdata .= build_issue_data($projdata);
}

print "Saving CSV data...\n";
save_file($outfile, $outdata);

print "Complete.\n";