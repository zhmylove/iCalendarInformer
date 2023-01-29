#!/bin/bash -e

cd /home/korg/ical_informer
export LC_ALL=C LANG=C PERL5LIB="$PWD/local/lib/perl5"

exec "$@"
