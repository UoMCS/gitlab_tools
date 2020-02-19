#!/usr/bin/env perl

use v5.12;
use strict;
use GitLab::API::Utils;
use Config::Tiny;
use Getopt::Long;
use Pod::Usage;

## @fn void clone_repository($url)
# Attempt to clone the repository at the specified URL. This
# tries to clone the repository at the URL and prints out
# the status of the clone.
#
# @param url The URL to clone the repository from.
sub clone_repository {
    my $url = shift;

    my $res = `git clone $url`;
    if($?) {
        print "ERROR: Cloning '$url' failed. Output:\n$res\n";
    } else {
        print "Cloned $url\n";
    }
}


# Turn on autoflushing
$| = 1;

my $man        = 0;  # Output the manual?
my $help       = 0;  # Output the summary options
my $configname = '/etc/gitlab.cfg'; # Which configuration should be loaded?
my $groupname  = ''; # Name of the gitlab group to list
my $clone      = 0;  # Should repos be cloned?

# Turn on bundling
Getopt::Long::Configure("bundling");

# Process the command line. Explicitly include abbreviations to get around the
# counterintuitive behaviour of Getopt::Long regarding autoabbrev and bundling.
GetOptions('f|config:s'  => \$configname,
           'g|group=s'   => \$groupname,
           'c|clone'     => \$clone,
           'h|help|?'    => \$help,
           'm|man'       => \$man);

# Send back the usage if help has been requested, or there's no group to process.
pod2usage(-verbose => 0) if($help || !$groupname);
pod2usage(-exitstatus => 0, -verbose => 2) if $man;

my $settings = Config::Tiny -> read($configname)
    or die "Config file open failed: ".Config::Tiny -> errstr."\n";

my $api = GitLab::API::Utils -> new(url   => $settings -> {"gitlab"} -> {"url"},
                                    token => $settings -> {"gitlab"} -> {"token"});

# Fetch the data for the group - ensures the group exists, and fetches the ID
my $group = $api -> lookup_group($groupname);
die "No group matching '$groupname' found in GitLab.\n"
    unless($group);

die "Unable to get group ID for '$groupname'\n"
    unless($group -> {"id"});

# Pull the list of projects in the group
my $projects = $api -> {"api"} -> call("/groups/:id/projects", "GET", { id => $group -> {"id"} })
    or die "Error fetching project list: ".$api -> {"api"} -> errstr()."\n";

# And print the URLs
foreach my $proj (@{$projects}) {
    print $proj -> {"ssh_url_to_repo"},"\n";
    clone_repository($proj -> {"ssh_url_to_repo"})
        if($clone);
}

# Are there more pages to fetch?
while($api -> {"api"} -> next_page()) {
    my $res = $api -> {"api"} -> call_url("GET", $api -> {"api"} -> next_page())
        or die "Project listing failed: ".$api -> {"api"} -> errstr()."\n";

    foreach my $proj (@{$res}) {
        print $proj -> {"ssh_url_to_repo"},"\n";
        clone_repository($proj -> {"ssh_url_to_repo"})
            if($clone);
    }
}


__END__

=head1 NAME

gitlab_group_list.pl - List the repositories in a gitlab group

=head1 SYNOPSIS

gitlab_group_list.pl [OPTIONS]

 Options:
    -h, -?, --help           Show a brief help message.
    -m, --man                Show full documentation.
    -f, --config             Name of the configuration to use.
    -g, --group              Name of the gitlab group to list.
    -c, --clone              Clone repositories to the current dir.

=head1 OPTIONS

=over 8