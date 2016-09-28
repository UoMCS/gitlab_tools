#!/usr/bin/perl

# A script to bulk-add all users on a course to a single gitlab project.
#
# Pass it a gitlab project ID as the first argument, and a course code
# as the second.

use strict;
use v5.14;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use Text::Sprintf::Named qw(named_sprintf);
use GitLab::API::Basic;
use REST::Client;
use JSON;
use Data::Dumper;

## @method void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: course_to_project.pl <projectID> <course>\n";
}


## @fn @ fetch_course_users($gitlab, $udata, $course)
# Fetch the list of gitlab ID numbers for users enrolled on the specified course.
#
#
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


sub set_project_users {
    my $gitlab = shift;
    my $projid = shift;
    my $users  = shift;

    foreach my $userid (@{$users}) {
        print "DEBUG: Adding user $userid to project $projid...\n";
#        my $res = $api -> call("/projects/:id/members", "POST", { id           => $projid,
#                                                                  user_id      => $userid,
#                                                                  access_level => 30 } )
#            or die "Unable to set permissions for ".$userid." on $projid: ".$api -> errstr()."\n";
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

my $gitlab = GitLab::API::Basic -> new(url   => $config -> {"gitlab"} -> {"url"},
                                       token => $config -> {"gitlab"} -> {"token"});

my $udata = REST::Client -> new({ host => $udataconfig -> {"API"} -> {"url"} })
    or die "Failed to create REST Client\n";
$udata -> addHeader("Private-Token", $udataconfig -> {"API"} -> {"token"});

my ($users, $failures) = fetch_course_users($gitlab, $udata, $course);
print "DEBUG: Got ".scalar(@{$users})." users to add\n".scalar(@{$failures})." lookups failed:\n\t".join("\n\t", @{$failures})."\nIgnoring failed users.\n";

set_project_users($gitlab, $projectid, $users);