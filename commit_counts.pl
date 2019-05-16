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

my $cmdfmt = '/usr/bin/git --bare shortlog -ens --no-merges --since="%(since)s"  --until="%(until)s" --date=local --all';


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


## @fn void prepare_counters($group)
# Given a group reference, initialise a hash of commit counts for
# each user in the group.
#
# @param group A reference to a hash containing the group data.
sub prepare_counters {
    my $group = shift;

    foreach my $user (@{$group -> {"users"}}) {
        $group -> {"commits"} -> {$user -> {"username"}} = { "user"  => $user,
                                                             "count" =>  0 };
    }
}


## @method $ fetch_commit_counts($path, $base, $team, $start, $finish)
# Obtain the number of commits made by a team between the start and
# finish dates specified.
#
# @param path   The path of the directory containing the bare git repos
#               for the course
# @param base   The base name for repositories, should be something like "stendhal"
# @param team   The name of the team to fetch commit counts for
# @param start  The start date to count commits from
# @param finish The end date to count commits to
# @return A string containing the number of commits made by each user who
#         has commited to the repo between the dates specified in the form
#         <count> <name> <email>
#         with one user per line.
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
    die "Git command failed: $result - $?"
        if($?);

    return $result;
}


## @method $ find_user($group, $name, $email)
# Attempt to determine which of the known users the specified name or
# email address corresponds to. This will attempt to find the username
# for a known user who either has the specified name as their username
# or real name, or for whom the specified email address is an exact
# match.
#
# @param group A reference to a hash containing the group information.
# @param name  The name of the user to try to find
# @param email The email address of the user to find
# @return The username of a known user if a match is found, otherwise
#         a string indicating that the user can't be matched.
sub find_user {
    my $group = shift;
    my $name  = shift;
    my $email = shift;

    foreach my $user (@{$group -> {"users"}}) {
        return $user -> {"username"}
        if(lc($user -> {"email"}) eq lc($email) ||
           lc($user -> {"username"}) eq lc($name) ||
           lc($user -> {"fullname"}) eq lc($name));
    }

    return "!!! $name <$email>";
}


## @method set_commit_count($group, $record)
# Given a group and the information about the number of commits a
# user with access to the repository made, try to calculate the commit
# counts for the user, merging similar users when possible.
#
# @param group  A reference to a hash containing the group data.
# @param record A string containing the commit counts for a single
#               user who committed to the repo.
sub set_commit_count {
    my $group  = shift;
    my $record = shift;

    my ($count, $name, $email) = $record =~ /^\s+(\d+)\s+([^<]+)<(.*?)>/;
    die "Unable to parse line '$record'\n"
        unless(defined($count) && $name && defined($email));

    # Trim leading and trailing spaces and [ ]
    $name  =~ s/^\s*\[?(.*?)\]?\s*$/$1/;
    $email =~ s/^\s*\[?(.*?)\]?\s*$/$1/;

    # Try to work out who the user in the record really is
    my $username = find_user($group, $name, $email);

    # And increment the counter for that user
    $group -> {"commits"} -> {$username} -> {"count"} += $count;
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

# Work out the commit counts for each group
foreach my $group (sort { $a -> {"name"} cmp $b -> {"name"} } @{$groupdata}) {
    prepare_counters($group);

    # obtain the list of users who committed to the repository
    my $result = fetch_commit_counts($path, $base, $group -> {"name"}, $start, $finish);

    # For each of the users who commited, work out the commit counts after merging
    my @lines = split(/^/, $result);
    foreach my $line (@lines) {
        set_commit_count($group, $line);
    }

    # And print out the summary information
    print $group -> {"name"},"\n";
    foreach my $name (sort { $group -> {"commits"} -> {$b} -> {"count"} <=> $group -> {"commits"} -> {$a} -> {"count"} } keys %{$group -> {"commits"}}) {
       my $commits = $group -> {"commits"} -> {$name};
        print "\t",$commits -> {"count"},": ",$name," ",$commits -> {"user"} -> {"fullname"},"\n";
     }
    print "\n";
}
