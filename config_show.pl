#!/usr/bin/perl

use strict;
use warnings;
use Storable qw( lock_retrieve );
use Getopt::Long;
use Data::Dumper;

my $file = "data.db";

GetOptions "file=s" => \$file or die "Invalid options";
die "Unknown options: @ARGV" if @ARGV;

my $config = lock_retrieve $file;
print Dumper $config;
