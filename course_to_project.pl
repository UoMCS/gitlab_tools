#!/usr/bin/perl

# A script to bulk-add all users on a course to a single gitlab project.
#
# Pass it a gitlab project ID as the first argument, a course code
# as the second, and the access level ('gues', 'reporter', 'developer', etc)
# as the third.

use strict;
use v5.14;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use Text::Sprintf::Named qw(named_sprintf);
use GitLab::API::Basic;
use REST::Client;
use JSON;
use Data::Dumper;

my $dryrun = 1;


## @method void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: course_to_project.pl <projectID> <course> <level>\n";
}


## @fn @ fetch_course_users($gitlab, $udata, $course)
# Fetch the list of gitlab ID numbers for users enrolled on the specified course.
#
# @param gitlab A reference to a gitlab API object to issue queries through.
# @param udata  A reference to a userdata API object to issue queries through.
# @param course The name of the course to fetch the user list for.
# @return two arrayrefs; the first is a reference to an array of gitlab user IDs
#         to add to the project, the second is a list of users who couldn't be
#         resolved to gitlab user IDs.
sub fetch_course_users {
    my $gitlab = shift;
    my $udata  = shift;
    my $course = shift;

    # First get the list of users on the course
    my $resp = $udata -> GET("/courses/current/users/$course?type=student");
    my $json = decode_json($resp -> responseContent());

    # Pick up and fall over from errors
    die "Unable to fetch user list from API. Error was:\n".$json -> {"error"} -> {"info"}."\n"
        if(ref($json) eq "HASH" && $json -> {"error"});

    # Now we need to convert these to a list of userids
    my ( $users, $failures );
    foreach my $user (@{$json}) {
        print "DEBUG: Looking up ".$user -> {"user"} -> {"username"}.": ".$user -> {"user"} -> {"email"}."... ";
        my $res = $gitlab -> call("/users", "GET", { search => $user -> {"user"} -> {"email"} });
        if($res && scalar(@{$res})) {
            push(@{$users}, $res -> [0] -> {"id"});
            print "uid: ".$res -> [0] -> {"id"}."\n";
        } else {
            push(@{$failures}, $user -> {"user"} -> {"user_id"}.": ".$user -> {"user"} -> {"username"}.", ".$user -> {"user"} -> {"email"});
            print "failed.\n";
        }
    }

    return ($users, $failures)
}


## @fn void set_project_users($gitlab, $projid, $users, $levelid)
# Given a project ID and list of users, add the users to the project as
# the specified level (defaults to 'developer')
#
# @param gitlab  A reference to a gitlab API object to work through.
# @param projid  The ID of the project to add the users to.
# @param users   A reference to an array of gitlab user IDs.
# @param levelid The access level to add users at. Defaults to 30 ('developer').
sub set_project_users {
    my $gitlab  = shift;
    my $projid  = shift;
    my $users   = shift;
    my $levelid = shift // 30;

    foreach my $userid (@{$users}) {
        print "DEBUG: Adding user $userid with level $levelid to project $projid...\n";
        if(!$dryrun) {
            my $res = $gitlab -> call("/projects/:id/members", "POST", { id           => $projid,
                                                                         user_id      => $userid,
                                                                         access_level => $levelid } )
                or die "Unable to set permissions for ".$userid." on $projid: ".$gitlab -> errstr()."\n";
        }
    }
}

my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $udataconfig = Webperl::ConfigMicro -> new("config/userdata.cfg")
    or die "Error: Unable to load userdata configuration: $!\n";

# Turn on autoflushing
$| = 1;

my $projectid = shift @ARGV or arg_error("No project ID specified.");
my $course    = shift @ARGV or arg_error("No course specified.");
my $level     = shift @ARGV or arg_error("No level specified.");

my $gitlab = GitLab::API::Basic -> new(url   => $config -> {"gitlab"} -> {"url"},
                                       token => $config -> {"gitlab"} -> {"token"});

my $udata = REST::Client -> new({ host => $udataconfig -> {"API"} -> {"url"} })
    or die "Failed to create REST Client\n";
$udata -> addHeader("Private-Token", $udataconfig -> {"API"} -> {"token"});

# convert the level
my $levelid = $gitlab -> {"access_levels"} -> {$level}
    or die "The specified level is not valid. Valid levels are: ".join(", ", keys(%{$gitlab -> {"access_levels"}}))."\n";

my ($users, $failures) = fetch_course_users($gitlab, $udata, $course);
print "DEBUG: Got ".scalar(@{$users})." users to add\n";
if($failures && scalar(@{$failures})) {
    print scalar(@{$failures})." lookups failed:\n\t".join("\n\t", @{$failures})."\nIgnoring failed users.\n";
}

set_project_users($gitlab, $projectid, $users, $levelid);