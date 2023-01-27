#!/usr/bin/perl

use strict;
use warnings;
use Storable qw( lock_nstore );
use Getopt::Long;

my $file = "data.db";
my $token;

GetOptions "token=s" => \$token, "file=s" => \$file or die "Invalid options";
die "Unknown options: @ARGV" if @ARGV;

die "Specify -token" unless $token;
die "$file already exists" if -f $file;
lock_nstore {token => $token, ics => {}} => $file;
