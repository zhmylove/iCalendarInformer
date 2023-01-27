#!/usr/bin/perl
# made by: KorG

use strict;
use warnings;
use lib qw( local/lib/perl5 );
use AnyEvent::Subprocess::Easy qw( qx_nonblock );
use AnyEvent;
use Getopt::Long;
use Storable qw( lock_retrieve );

# Read config
my $file = "data.db";
my $config = lock_retrieve($file);
my $uid;

GetOptions "file=s" => \$file, "uid=s" => \$uid;

# Validate config
exit 0 unless defined $config;
die "Token is empty" unless $config->{token};
die "ICS not found" unless defined $config->{ics};

my @jobs;

my @uids = keys %{ $config->{ics} };
@uids = grep { $_ eq $uid } @uids if defined $uid;

# Spawn children
push @jobs, qx_nonblock(
    "./processor.pl",
    -file => $config->{ics}->{$_},
    -chatid => $_,
    -token => $config->{token},
    @ARGV,
) for @uids;

# Wait for all children
for my $child (@jobs) {
    eval { $child->recv; 1 } or do {
        warn "Error: $@" if $ENV{DEBUG};
    };
}
