#!/usr/bin/perl

## @file
# A script to automate the process of updating Error and Symptom pages
# in the LabHelp namespace. Run this without arguments and it will scan
# the LAbHelp namespace looking for instances of the {{LabHelp::MetaList}}
# template, and collect page references defined within those instances
# into lists that get inserted into the Errors and Symptoms pages.
#
# This expects config/mediawiki.cfg to contain
#
# [wiki]
# url       = https://url.of.wiki/api.php
# username  = <username to log in with>
# password  = <password to log in with>
# namespace = <ID of the namespace to scan>
#
# errors    = LabHelp:Errors
# symptoms  = Labhelp:Symptoms
# startmark = <!-- PAGEGEN MARKER. DO NOT REMOVE -->
# endmark   = <!-- END PAGEGEN MARKER. DO NOT REMOVE -->


use v5.14;
use utf8;
use strict;
use MediaWiki::API;

use lib qw(/var/www/webperl);
use Webperl::ConfigMicro;
use Webperl::Utils qw(load_file);

use Data::Dumper;

## @fn void query_failed($api, $err)
# Exit the script wiht an error message after an API call failure.
#
# @param api A reference to a MediaWiki::API object
# @param err The error message to display. This will be shown before
#            the error details stored in the API object.
sub query_failed {
    my $api = shift;
    my $err = shift;

    die "$err\nError was: ".$api -> {"error"} -> {"code"}.":".$api -> {"error"} -> {"details"}."\n";
}


## @fn $ get_page_list($api, $namespace)
# Fetch a list of all pages in the target namespace.
#
# @param api       A reference to the MediaWiki::API object to use.
# @param namespace The ID of the namespace to list pages in.
# @return A reference to an array of hashrefs, each containing the
#         `pageid`, `title`, and `ns` namespace ID. Note that `title`
#         includes the namespace name.
sub get_page_list {
    my $api       = shift;
    my $namespace = shift;

    my $articles = $api -> list(
        {
            action      => 'query',
            list        => 'allpages',
            apnamespace => $namespace,
            aplimit     => 'max'
        })
        or query_failed($api, "Unable to fetch list of all pages");

    return $articles;
}


## @fn $ process_list_entries($list, $page, $store)
# Given a list of errors or symptoms, parse the list storing the
# page reference in the specified store hash.
#
# @param list A list containing '###'-separated errors or symptoms.
# @param page The title of the current mediawiki page the errors or
#             symptoms are associated with.
# @param store A reference to a hash containing the page reference store.
sub process_list_entries {
    my $list  = shift;
    my $page  = shift;
    my $store = shift;

    # Can't do anything if we have no list of things to process
    return unless($list);

    # Make sure we have no newlines messing up the list
    $list =~ s/\r?\n//g;

    # '###' is the split marker
    my @parts = split(/###/, $list);

    # Process each part of the list, storing it in the page reference store
    foreach my $part (@parts) {
        $part =~ s/^\s*(.*?)\s*$/$1/; # trim leading/trailing whitespace

        # Get the first character so we can store in alphanumeric subhashes
        my $list = uc(substr($part, 0, 1));

        push(@{$store -> {$list} -> {$part}}, $page);
    }
}


## @fn $ scan_page($api, $title, $errors, $symptoms)
# Search the contents of the specified wiki page looking for the
# LabHelp:MetaList template, and extract the errors and symptoms from it
# if found.
#
# @param api      A reference to a MediaWiki::API object to use.
# @param title    The title of the wiki page to process.
# @param errors   A reference to the error page reference store.
# @param symptoms A reference to the symptom page reference store.
sub scan_page {
    my $api      = shift;
    my $title    = shift;
    my $errors   = shift;
    my $symptoms = shift;

    my $page = $api -> get_page({ title => $title })
        or query_failed($api, "Unable to fetch page '$title'");

    my $content = $page -> {"*"};

    # Convert {{dot}} to something literal, so we don't need to faff with a full parser
    $content =~ s/\{\{dot\}\}/###/g;

    # Pull out error and symptom lists. Note that they may appear in either order!
    my ($errlist) = $content =~ /\{\{LabHelp:MetaList\s*\|\s*(?:symptoms\s*=\s*[^|]+\|\s*)?errors\s*=\s*([^|}]+)/s;
    my ($symlist) = $content =~ /\{\{LabHelp:MetaList\s*\|\s*(?:errors\s*=\s*[^|]+\|\s*)?symptoms\s*=\s*([^|}]+)/s;

    process_list_entries($errlist, $title, $errors);
    process_list_entries($symlist, $title, $symptoms);
}


## @fn @ collect_references($api, $articles)
# Go through the list of articles in the LabHelp namespace, and extract
# all error and symptom page references.
#
# @param api      A reference to a MediaWiki::API object to use.
# @param articles A reference to an array of article hashrefs.
# @return A pair of hashrefs; the first is a reference to a hash of
#         error message to page names, the second is a hash of
#         symptom to page names.
sub collect_references {
    my $api      = shift;
    my $articles = shift;

    my ($errors, $symptoms) = ({}, {});

    foreach my $page (@{$articles}) {
        print "Checking ".$page -> {"title"}." for references...\n";

        scan_page($api, $page -> {"title"}, $errors, $symptoms);
    }

    return ($errors, $symptoms);
}


## @fn $ generate_page($refs)
# Given a reference to a hash containing page references, build a string
# to place into the appropriate wiki page describing the messages in the
# references hash, and the page(s) they refer to.
#
# @param refs A reference to a hash contianing alphanumerically-organised
#             page references.
# @return A string containing wiki markup to insert into a page
sub generate_page {
    my $refs   = shift;
    my $result = "";

    foreach my $char (sort keys(%{$refs})) {
        $result .= "=== $char ===\n";

        foreach my $message (sort keys(%{$refs -> {$char}})) {
            # Add the message as a <dl><dh>....</dh> inside a list
            $result .= "*; <code>$message</code> has a possible solution on:\n";

            foreach my $page (sort @{$refs -> {$char} -> {$message}}) {
                # Pull out a nicer name without namespace and path
                my ($nicename) = $page =~ m|^(?:.*?:)?(?:.*?/)(.*)$|;


                # And add the page links as <dd> children of the same list
                $result .= "*: [[$page|".($nicename // $page)."]]\n";
            }

            $result .= "\n";
        }
    }

    return $result;
}


## @fn void edit_page($api, $text, $title, $smarker, $emarker)
# Update the text of the specified wiki page with the provided text.
# This fetches the page content, replaces everything between $smarker
# and $emarker with the provided text, and then edits the page with
# the updated content.
#
# @param api     A reference to a MediaWiki::API object to use.
# @param text    A string to insert between $smarker and $emarker.
# @param title   The mediawiki title of the page to update.
# @param smarker The marker in the page that indicates where to start
#                inserting generated text at.
# @param emarker The marker in the page that indicates where the end
#                of the automatically generated text should be.
sub edit_page {
    my $api     = shift;
    my $text    = shift;
    my $title   = shift;
    my $smarker = shift;
    my $emarker = shift;

    # First retrieve the current page content
    my $page = $api -> get_page({ title => $title })
        or query_failed($api, "Unable to fetch page '$title'");

    my $content = $page -> {"*"};

    # replace the text betwixt the markers
    $content =~ s/$smarker.*?$emarker/$smarker\n$text$emarker/s;

    # Update the page!
    $api -> edit(
        {
            action => 'edit',
            title  => $title,
            basetimestamp => $page -> {timestamp},
            text => $content
        })
        or query_failed($api, "Unable to update page '$title'");
}


# Load the configuration, and set up the mediawiki connection
my $config = Webperl::ConfigMicro -> new("config/mediawiki.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $mw = MediaWiki::API -> new(
    {
        api_url => $config -> {"wiki"} -> {"url"}
    });

$mw->login(
    {
        lgname     => $config -> {"wiki"} -> {"username"},
        lgpassword => $config -> {"wiki"} -> {"password"}
    })
    or die $mw->{error}->{code} . ': ' . $mw->{error}->{details};

# Fetch the list of pages in the namespace, and then pull out page references
my $articles = get_page_list($mw, $config -> {"wiki"} -> {"namespace"});
my ($errors, $symptoms) = collect_references($mw, $articles);

# And now update the wiki with the processed references
print "Updating ".$config -> {"wiki"} -> {"errors"}."\n";
edit_page($mw,
          generate_page($errors),
          $config -> {"wiki"} -> {"errors"},
          $config -> {"wiki"} -> {"startmark"},
          $config -> {"wiki"} -> {"endmark"});

print "Updating ".$config -> {"wiki"} -> {"symptoms"}."\n";
edit_page($mw,
          generate_page($symptoms),
          $config -> {"wiki"} -> {"symptoms"},
          $config -> {"wiki"} -> {"startmark"},
          $config -> {"wiki"} -> {"endmark"});

print "Done.\n";
