#!/usr/bin/perl

use v5.12;
use strict;
use Config::Tiny;
use Getopt::Long;
use Pod::Usage;
use JSON;

## @fn $ path_join(@fragments)
# Take an array of path fragments and concatenate them together. This will
# concatenate the list of path fragments provided using '/' as the path
# delimiter (this is not as platform specific as might be imagined: windows
# will accept / delimited paths). The resuling string is trimmed so that it
# <b>does not</b> end in /, but nothing is done to ensure that the string
# returned actually contains a valid path.
#
# @param fragments An array of path fragments to join together. Items in the
#                  array that are undef or "" are skipped.
# @return A string containing the path fragments joined with forward slashes.
sub path_join {
    my @fragments = @_;
    my $leadslash;

    # strip leading and trailing slashes from fragments
    my @parts;
    foreach my $bit (@fragments) {
        # Skip empty fragments.
        next if(!defined($bit) || $bit eq "");

        # Determine whether the first real path has a leading slash.
        $leadslash = $bit =~ m|^/| unless(defined($leadslash));

        # Remove leading and trailing slashes
        $bit =~ s|^/*||; $bit =~ s|/*$||;

        # If the fragment was nothing more than slashes, ignore it
        next unless($bit =~ /\S/);

        # Store for joining
        push(@parts, $bit);
    }

    # Join the path, possibly including a leading slash if needed
    return ($leadslash ? "/" : "").join("/", @parts);
}


my $man        = 0;  # Output the manual?
my $help       = 0;  # Output the summary options
my $configname = '/etc/tagcheck.cfg'; # Which configuration should be loaded?
my $groupname  = '';
my $tagname    = '';

# Turn on bundling
Getopt::Long::Configure("bundling");

# Process the command line. Explicitly include abbreviations to get around the
# counterintuitive behaviour of Getopt::Long regarding autoabbrev and bundling.
GetOptions('f|config:s'  => \$configname,
           'g|group=s'   => \$groupname,
           't|tag=s'     => \$tagname,
           'h|help|?'    => \$help,
           'm|man'       => \$man);

# Send back the usage if help has been requested, or there's no group to process.
pod2usage(-verbose => 0) if($help || !$groupname || !$tagname);
pod2usage(-exitstatus => 0, -verbose => 2) if $man;

my $settings = Config::Tiny -> read($configname)
    or die "Config file open failed: ".Config::Tiny -> errstr."\n";

my $checkdir = path_join($settings -> {"repos"} -> {"path"},
                         $groupname);

opendir(REPOS, $checkdir)
    or die "Unable to open repo directory '$checkdir': $!\n";
my @entries = grep {!/.wiki.git$/} readdir(REPOS);
closedir(REPOS);

my %students;
foreach my $dir (@entries) {
    next if($dir =~ /^\./);

    my ($username) = $dir =~ /_([a-z0-9]+).git$/;
    next unless($username);

    my $gitdir = path_join($checkdir, $dir);
    $students{$username} = `git --git-dir=$gitdir branch -a --contains=$tagname 2>&1`;
    chomp $students{$username};
}

print encode_json(\%students);
