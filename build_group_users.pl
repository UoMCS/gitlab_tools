#!/usr/bin/perl

use strict;
use v5.14;
use lib qw(/var/www/webperl);

use Webperl::Utils qw(path_join load_file save_file);
use Webperl::ConfigMicro;
use File::Path qw(make_path);
use Text::Sprintf::Named qw(named_sprintf);
use Data::Dumper;

use GitLab::API::Basic;
use LWP::UserAgent;
use JSON;

## @fn $ generate_password($length, $wiggle)
# Generate a password containing random upper, lower, and numeric
# characters of the specified length.
#
# @param length The length of the password to generate.
# @param wiggle The amount to randomly add or remove from length.
# @return A string containing the generated password.
sub generate_password {
    my $length = shift;
    my $wiggle = shift;

    $length += $wiggle - int(rand((2 * $wiggle) + 1));

    # Possibly consider using true entropy source rather than rand
    return join("", map { ("a".."z", "A".."Z", 0..9)[rand 62] } 1..$length);
}


## @fn @ generate_credentials($groupname, $settings)
# Given a group name, generate the user's ssh key and passwords.
#
# @param groupname The name of the group to generate a key and passwords for
# @param settings  A reference to the global settings object
# @return An array containing the user password, private key password,
#         and private key filename (add .pub to get public key)
sub generate_credentials {
    my $groupname = shift;
    my $settings  = shift;

    my $keypath  = path_join($settings -> {"groups"} -> {"base"}, $groupname);
    make_path($keypath);

    my $keyfile  = path_join($keypath, "id_rsa");
    my $keypass  = generate_password($settings -> {"groups"} -> {"password_length"},
                                     $settings -> {"groups"} -> {"password_vary"});

    my $madekey = `/usr/bin/ssh-keygen -q -t rsa -b 4096 -C '$groupname' -N '$keypass' -f '$keyfile'`;
    die "Unable to generate key for '$groupname': $madekey"
        if($madekey);

    my $userpass = generate_password($settings -> {"groups"} -> {"password_length"},
                                     $settings -> {"groups"} -> {"password_vary"});

    save_file(path_join($keypath, "keypass"), $keypass);
    save_file(path_join($keypath, "userpass"), $userpass);

    return ($userpass, $keypass, $keyfile);
}


## @fn $ add_gitlab_user($username, $userpass, $api, $settings)
# Attempt to add the specified user to GitLab with the provided password.
# The email address for the user is generated using the email_format
# specified in the configuration and the username. The account is
# created with confirm disabled!
#
# @param username The name (and username) of the user to add.
# @param userpass The password to set for the user.
# @param api      A reference to a GitLab::API::Basic object.
# @param settings A reference to a global settings object.
# @return The new user ID on success. Dies on error.
sub add_gitlab_user {
    my $username = shift;
    my $userpass = shift;
    my $api      = shift;
    my $settings = shift;

    my $result = $api -> call("/users", "POST", { "email"    => named_sprintf($settings -> {"groups"} -> {"email_format"}, { "group" => $username }),
                                                  "password" => $userpass,
                                                  "username" => $username,
                                                  "name"     => $username,
                                                  "confirm"  => 'false' })
        or die "Unable to add user $username to GitLab: ".$api -> errstr()."\n";

    return $result -> {"id"};
}


## @fn void add_gitlab_key($userid, $username, $keyfile, $api, $settings)
# Add the public key in the specified file to the user's keys in gitlab.
#
# @param userid    The ID of the user to add the key to in gitlab
# @param username  The username of the user to add the key to
# @param keyfile   The full path to the *public* key to add
# @param api      A reference to a GitLab::API::Basic object.
# @param settings A reference to a global settings object.
sub add_gitlab_key {
    my $userid   = shift;
    my $username = shift;
    my $keyfile  = shift;
    my $api      = shift;
    my $settings = shift;

    my $key = load_file($keyfile)
        or die "Unable to load public key for '$username' from '$keyfile': $!\n";

    $api -> call("/users/:id/keys", "POST", { "id"    => $userid,
                                              "title" => "$username-key",
                                              "key"   => $key })
        or die "Unable to add public key for user $username: ".$api -> errstr()."\n";
}


## @fn void add_jenkins_key($username, $keyfile, $keypass, $settings)
# Add the private key and key password as a credential in Jenkins.
#
# @param username The username to add the credential as. This is also used as the ID.
# @param keyfile  The filename of the private key
# @param keypass  The passphrase for the private key
# @param settings A reference to a global settings object.
sub add_jenkins_key {
    my $username = shift;
    my $keyfile  = shift;
    my $keypass  = shift;
    my $settings = shift;

    my $key = load_file($keyfile)
        or die "Unable to load private key for '$username' from '$keyfile': $!\n";

    # WARNING WARNING WARNING
    # What follows is blatant Cargo Cult Coding. This seems to work, but it
    #
    # a) relies on faking a form post
    # b) uses as-far-as-I-can-tell undocumented features of the credentials code
    # c) may stop working without warning if jenkins changes
    # d) is really bloody horrible compared to the sane REST endpoint that should
    #    be there but either isn't, or isn't documented.
    #
    # In short: it's a godsaful mess that I'm vaguely ashamed to be using, but
    # needs must as the devil vomits into your kettle.
    my $ua = LWP::UserAgent -> new();
    my $data = { "credentials" =>
                 {
                     'scope' => 'GLOBAL',
                     'id' => $username,
                     'username' => $username,
                     'description' => "$username credential",
                     'passphrase' => $keypass,
                     'stapler-class' => 'com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey',
                     'kind' => 'com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey',
                     'privateKeySource' => {
                         'value' => "0",
                         'privateKey' => $key,
                         'stapler-class' => 'com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey$DirectEntryPrivateKeySource'
                     }
                 }
    };

    # Jenkins requires a CSRF header in requests
    my $result = $ua -> get($settings -> {"jenkins"} -> {"base"}.$settings -> {"jenkins"} -> {"csrf"});
    die "Jenkins CSRF request failed: ".$result -> status_line."\n"
        unless($result -> is_success);

    my $csrf = decode_json($result -> decoded_content);
    die "CSRF response invalid: ".Dumper($csrf)."\n"
        unless($csrf -> {"crumb"} && $csrf -> {"crumbRequestField"});

    $ua -> default_header($csrf -> {"crumbRequestField"} => $csrf -> {"crumb"});

    $data -> {"json"} -> {"Jenkins-Crumb"} = $csrf -> {"crumb"};

    # Create the credential in Jenkins
    my $result = $ua -> post($settings -> {"jenkins"} -> {"base"}.$settings -> {"jenkins"} -> {"cred"},
                             Content => { "json" => encode_json($data),
                                          "Submit" => "OK"});
    die "Jenkins request failed: ".$result -> status_line."\n"
        unless($result -> is_success || $result -> status_line eq "302 Found");
}


my $config = Webperl::ConfigMicro -> new("config/gitlab.cfg")
    or die "Error: Unable to load configuration: $!\n";

my $gitlab = GitLab::API::Basic -> new(url   => $config -> {"gitlab"} -> {"url"},
                                       token => $config -> {"gitlab"} -> {"token"});

# Pull the arguments
my ($year, $course, $group, $minid, $maxid) = @ARGV;
die "Usage: build_group_users.pl <year> <course> <group> <min id> <max id>\n"
    unless($year && $year =~ /^\d{4}$/ && $course && $group && $minid && $maxid && ($minid <= $maxid));

foreach my $id ($minid..$maxid) {
    my $gid = ( $id < 10 ? "0$id" : $id);
    my $groupname = named_sprintf($config -> {"groups"} -> {"name_format"}, { year => $year,
                                                                              course => $course,
                                                                              group  => $group,
                                                                              id     => $gid });
    print "Going to add group user '$groupname'...\n";
    print "\tCreating credentials...\n";
    my ($userpass, $keypass, $keyfile) = generate_credentials($groupname, $config);

    print "\tAdding user to gitlab...\n";
    my $userid = add_gitlab_user($groupname, $userpass, $gitlab, $config);

    print "\tAdding public key to gitlab...\n";
    add_gitlab_key($userid, $groupname, $keyfile.".pub", $gitlab, $config);

    print "\tAdding private key to jenkins...\n";
    add_jenkins_key($groupname, $keyfile, $keypass, $config);

    print "Group $groupname id: $userid\n"
}
