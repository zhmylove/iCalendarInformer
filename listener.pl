#!/usr/bin/perl
# made by: KorG

use strict;
use warnings;
use Getopt::Long;
use Storable qw( lock_nstore lock_retrieve );
use WWW::Telegram::BotAPI;

my $file = "data.db";

GetOptions "file=s" => \$file or die "Invalid options";
die "Unknown options: @ARGV" if @ARGV;

my $config = lock_retrieve $file;

sub save_config {
    lock_nstore $config => $file;
}

for ($config, @{ $config }{qw( token ics )}) {
    unless (defined $_) {
        warn "Config is invalid" if $ENV{DEBUG};
        exit 0;
    }
}

my $tg = WWW::Telegram::BotAPI->new(token => $config->{token});
die "I am not a bot" unless $tg->getMe->{result}{is_bot};

sub sendMessage {
    my $chat_id = shift;
    my $text = shift;

    eval { $tg->sendMessage({ chat_id => $chat_id, text => $text }); 1 } or do {
        warn "Error sending message [ $chat_id => $text ]" if $ENV{DEBUG};
    };
}

my $updates;
my $offset = $config->{offset};
for(;;) {
    eval {
        $updates = $tg->getUpdates({ timeout => 30, $offset ? (offset => $offset) : () });
        1;
    } or do {
        warn "getUpdates failed: $@" if $ENV{DEBUG};
        next;
    };

    next unless ref $updates eq "HASH" and $updates->{ok};

    for my $upd (@{ $updates->{result} }) {
        $offset = $upd->{update_id} + 1 if $upd->{update_id} >= ($offset || 0);

        next unless (my $text = $upd->{message}{text});

        warn "Text: [ $text ]" if $ENV{DEBUG};

        $text =~ s/^\s*//;
        $text =~ s/\s*$//;

        if ($text eq "/help") {
            sendMessage($upd->{message}{chat}{id}, "Outlook calendar notifications bot");
            next;
        }

        if ($text =~ m,^/(today|tomorrow|next)$,s) {
            my $mode = $1;
            my $pid;
            die "Fork error" unless defined($pid = fork());
            next if $pid;

            exec { "./runner.pl" } "./runner.pl", -uid => $upd->{message}{chat}{id}, "--", -day => $mode;
            die "Exec error";
        }

        if ($text eq "/ics") {
            $config->{offset} = $offset;
            save_config();
            sendMessage($upd->{message}{chat}{id}, 'Proper command format: `/ics disable` or `/ics https://URL-for-calendar.ics`');
            next;
        }

        if ($text eq "/ics disable") {
            delete $config->{ics}->{ $upd->{message}{chat}{id} };
            $config->{offset} = $offset;
            save_config();
            sendMessage($upd->{message}{chat}{id}, "ICS disabled successfully");
            next;
        }

        if ($text =~ m,/ics (https?://\S+)$,s) {
            my $url = $1;

            unless ($url =~ m,\.ics$,) {
                sendMessage($upd->{message}{chat}{id}, "URL does not look like .ics");
                next;
            }

            $config->{ics}->{ $upd->{message}{chat}{id} } = $url;
            $config->{offset} = $offset;
            save_config();
            sendMessage($upd->{message}{chat}{id}, "ICS enabled successfully");
            next;
        }
    }
}
