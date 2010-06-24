#!/usr/bin/perl

# This is a dummy, its purpose is to call a script with the same name in the buildtools repository

$0 =~ s/(.*[\\\/])//g;
chdir($1) if $1;

do "buildtools/$0";
die $@ if $@;

`mkdir /tmp/adblockplus 2> /dev/null`;
`unzip -o ~/projects/adblockplus/adblockplus.xpi -d /tmp/adblockplus`;
die $@ if $@;
