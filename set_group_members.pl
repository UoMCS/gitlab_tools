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

use Webperl::ConfigMicro;
use REST::Client;
use JSON;
use Data::Dumper;

## @fn void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: set_group_members.pl <course> <teamfile>\n";
}


sub get_id_from_email {
    my $rest  = shift;
    my $email = shift;

    $email =~ s/@/%40/;

    my $resp = $rest -> GET("/users/current/user/$email");
    my $json = decode_json($resp -> responseContent());

    die "Error response: ".Dumper($json)
        unless(ref($json) eq "ARRAY");

    return($json -> [0] -> {"user"} -> {"spotid"})
        if($json -> [0] -> {"user"} -> {"spotid"});

    die "Unable to locate user with email $email: $json\n";
}


## @fn $ load_teams($teamfile, $config)
# Load the team member allocations from the specified team file. This will
# attempt to read team allocations from the file and store them in a hash
# of team member arrays for later processing.
#
# @param teamfile The name of the file to read team information from.
# @param config   A reference to the global configuration object
# @return A reference to a hash containing team member arrays.
sub load_teams {
    my $teamfile = shift;
    my $config   = shift;
    my $rest     = shift;
    my $teams    = {};
    my $line;

    open(DATA, "< $teamfile")
        or die "Unable to open team file '$teamfile': $!\n";

    # Process the headers
    chomp($line = <DATA>);

    my @headers = split(/,/, lc($line));

    # Convenience variables for readability
    my $teamfield = $config -> {"Teams"} -> {"teamfield"};
    my $idfield   = $config -> {"Teams"} -> {"idfield"};
    my $mailfield = $config -> {"Teams"} -> {"mailfield"};

    while($line = <DATA>) {
        chomp($line);
        my %vals;
        @vals{@headers} = split(/,/, $line);

        die "No data for team field ($teamfield) or data field ($idfield/$mailfield) on line '$line':\n".Dumper(\%vals)."\n"
            unless($vals{$teamfield} && ($vals{$idfield} || $vals{$mailfield}));

        # If we have mail field, but no id, look an ID up
        $vals{$idfield} = get_id_from_email($rest, $vals{$mailfield});

        push(@{$teams -> {$vals{$teamfield}}}, $vals{$idfield});
    }

    close(DATA);
    return $teams;
}


my $config = Webperl::ConfigMicro -> new("config/userdata.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $course   = shift @ARGV or arg_error("No course specified.");
my $teamfile = shift @ARGV or arg_error("No team file specified.");

print "Reading team file $teamfile...\n";

# Need a REST API object to issue queries through
my $rest = REST::Client -> new({ host => $config -> {"API"} -> {"url"} })
    or die "Failed to create REST Client\n";

$rest -> addHeader("Private-Token", $config -> {"API"} -> {"token"});

# Pull in the team data
my $teams = load_teams($teamfile, $config, $rest);
print "Got ".scalar(keys(%{$teams}))." teams, adding users to teams...\n";

# Process each team, adding members to the teams
foreach my $team (sort keys(%{$teams})) {
    print "\tAdding users to '$team'...\n";

    foreach my $user (@{$teams -> {$team}}) {
        print "\t\t$user... ";

        my $resp = $rest -> POST("/courses/current/groups/$course/group/$team/member/$user");
        my $json = decode_json($resp -> responseContent());

        if(ref($json) eq "HASH" && $json -> {"error"}) {
            print "failed: ".$json -> {"error"} -> {"info"}."\n";
        } else {
            print "done\n";
        }
    }
}

print "Finished processing.\n";
