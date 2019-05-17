#!/usr/bin/perl

# Extract the issue data for forked projects for marking.

use strict;
use v5.12;
use lib qw(/var/www/webperl);

use experimental qw("smartmatch");
use Webperl::ConfigMicro;
use Webperl::Utils qw(load_file save_file path_join);
use Webperl::Template;
use Text::Markdown 'markdown';
use GitLab::API::Utils;
use Data::Dumper;
use FindBin;

# Work out where the script is, so module and config loading can work.
my $scriptpath;
BEGIN {
    if($FindBin::Bin =~ /(.*)/) {
        $scriptpath = $1;
    }
}


## @method void arg_error($message)
# Print an error message indicating the correct invocation arguments for the script.
#
# @param message An error message to show before the usage information.
sub arg_error {
    my $message = shift;

    die "Error: $message\nUsage: markclone.pl <logfile>...\n";
}


sub build_comments {
    my $template = shift;
    my $notes    = shift;

    my $notehtml = "";
    foreach my $note (@{$notes}) {
        $notehtml .= $template -> load_template("comment.html", { "{T_[name]}"     => $note -> {"author"} -> {"name"},
                                                                  "{T_[username]}" => $note -> {"author"} -> {"username"},
                                                                  "{T_[date]}"     => $note -> {"created_at"},
                                                                  "{T_[comment]}"  => markdown($note -> {"body"})
                                                });
    }

    return $notehtml;
}


sub write_issues {
    my $template = shift;
    my $name     = shift;
    my $issues   = shift;
    my $file     = "$name.html";

    print "Writing issues for $name to '$file'... ";

    my $issuehtml = "";
    foreach my $issue (@{$issues}) {
        my $comments  = build_comments($template, $issue -> {"notes"});
        my $assignee  = $issue -> {"assignee"}  ? $issue -> {"assignee"} -> {"name"} : "Not set";
        my $milestone = $issue -> {"milestone"} ? $issue -> {"milestone"} -> {"title"} : "Not set";

        $issuehtml .= $template -> load_template("issue.html", { "{T_[title]}"     => $issue -> {"title"},
                                                                 "{T_[iid]}"       => $issue -> {"iid"},
                                                                 "{T_[state]}"     => $issue -> {"state"},
                                                                 "{T_[assignee]}"  => $assignee,
                                                                 "{T_[milestone]}" => $milestone,
                                                                 "{T_[comments]}"  => $comments,
                                                                 "{T_[issue]}"     => markdown($issue -> {"description"}),
                                                 });
    }

    save_file($file, $template -> load_template("issues.html", { "{T_[title]}"  => $name,
                                                                 "{T_[issues]}" => $issuehtml
                                                }));
    print "done\n";
}


## @method void process_log($api, $template, $file)
# Search through the specified log file to collect the fork IDs, and
# then go through the list of IDs and synchronise the issues with
# the source project.
#
# @param api      A reference to a GitLab::API::Utils object.
# @param template A reference to a Template object.
# @param file     The name of a log file to load the fork IDs from.
sub process_log {
    my $api      = shift;
    my $template = shift;
    my $file     = shift;

    my $logdata = load_file($file)
        or die "Unable to load log file: $!\n";

    my @ids = $logdata =~ /^Fork: [^:]+: (\d+)$/mg;

    foreach my $id (@ids) {
        my $project = $api -> {"api"} -> call("/projects/:id", "GET" , { id => $id });
        if($project) {
            print "Pulling issues and comments from ".$project -> {"name"}."... ";
            my $issues = $api -> fetch_issues($id);

            if($issues) {
                print "done.\n";
                write_issues($template, $project -> {"name"}, $issues);

            } else {
                print "\nERROR: ".$api -> errstr()."\n";
            }

        } else {
            print "ERROR: Unable to look up project $id: ".$api -> errstr()."\n";
        }
    }
}


my $config = Webperl::ConfigMicro -> new(path_join($scriptpath, "config", "gitlab.cfg"))
    or die "Error: Unable to load configuration: $!\n";

# Turn on autoflushing
$| = 1;

arg_error("No log files specified") unless(scalar(@ARGV));

my $api = GitLab::API::Utils -> new(url   => $config -> {"gitlab"} -> {"url"},
                                    token => $config -> {"gitlab"} -> {"token"});

$config -> {"config"} -> {"base"} = $scriptpath;
my $template = Webperl::Template -> new(settings => $config);

foreach my $file (@ARGV) {
    process_log($api, $template, $file);
}