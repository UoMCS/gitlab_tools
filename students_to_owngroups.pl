#!/usr/bin/perl

# Interrogate the API to fetch a list of students on the course
# and generate a JSON file containing their data in a way that
# allows labfork to create individual per-student forks of the
# source repostory (ie: one group per student)

use strict;
use v5.14;
use lib qw(/var/www/webperl);

use Webperl::ConfigMicro;
use Text::Sprintf::Named qw(named_sprintf);
use GitLab::API::Utils;
use REST::Client;
use JSON;
use Data::Dumper;


## @method void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: students_to_owngroups.pl <course>\n";
}


## @fn $ fetch_student_data($rest, $course)
# Fetch the student data from the UserData API for the specified course.
#
# @param rest   A reference to a REST::Client to issue queries through
# @param course The course to fetch the students for
# @return A reference to an array of student hashes.
sub fetch_student_data {
    my $rest   = shift;
    my $course = shift;

    my $resp = $rest -> GET("/courses/current/users/$course?type=student");
    my $json = decode_json($resp -> responseContent());

    # Pick up and fall over from errors
    die "Unable to fetch student list from API. Error was:\n".$json -> {"error"} -> {"info"}."\n"
        if(ref($json) eq "HASH" && $json -> {"error"});

    return $json;
}


## @fn $ build_group_list($data)
# Build the list of groups to create one group per user, with the user as the
# single group member.
#
# @param data A reference to an array of student records from the API
# @return A reference to an array of group hashes.
sub build_group_list {
    my $data   = shift;

    my @result;
    foreach my $user (@{$data}) {
        push(@result, { name  => $user -> {"user"} -> {"username"},
                        users => [ $user -> {"user"} ] });
    }

    return \@result;
}


## @fn void check_gitlab_accounts($api, $sudents)
# Determine whether the students specified have accounts in GitLab.
# This checks through the list of specified students and checks whether they
# have a matching account in GitLab (based on their email address, which should
# be unique, hopefully).
#
# @param api      A reference to a Gitlab API handle.
# @param students A reference to an array of student hashes to check.
sub check_gitlab_accounts {
    my $api      = shift;
    my $students = shift;

    foreach my $user (@{$students}) {
        my $res = $api -> {"api"} -> call("/users", "GET", { search => $user -> {"user"} -> {"email"} });

        unless($res && scalar(@{$res})) {
            print STDERR "Looking up ".$user -> {"user"} -> {"email"}." failed.\n";
        }
    }
}


my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $udataconfig = Webperl::ConfigMicro -> new("config/userdata.cfg")
    or die "Error: Unable to load userdata configuration: $!\n";

# Turn on autoflushing
$| = 1;

my $course = shift @ARGV or arg_error("No course specified.");

my $api = GitLab::API::Utils -> new(url   => $config -> {"gitlab"} -> {"url"},
                                    token => $config -> {"gitlab"} -> {"token"});

my $rest = REST::Client -> new({ host => $udataconfig -> {"API"} -> {"url"} })
    or die "Failed to create REST Client\n";
$rest -> addHeader("Private-Token", $udataconfig -> {"API"} -> {"token"});

# Fetch the student data from the userdata system
my $studentdata = fetch_student_data($rest, $course);
my $groupdata   = build_group_list($studentdata);

# Dump the JSON data to stdout so it can be redirected or piped
print JSON -> new -> utf8(1) -> pretty(1) -> encode($groupdata);

# Go through and check that students have gitlab accounts
check_gitlab_accounts($api, $studentdata);
