#!/usr/bin/perl
# made by: KorG

use strict;
use warnings;
use Data::ICal::DateTime;
use DateTime;
use Encode qw( decode_utf8 );
use Getopt::Long;
use LWP;
use Time::Piece;
use List::Util qw( any );
use WWW::Telegram::BotAPI;

# syncevolution --export - backend=evolution-calendar > cal.ics
# ... or share ICS from OWA via HTTP

# Default values go here
my $FILENAME = "cal.ics";
my $DAY = "";
my $DATE;
my $CHATID;
my $TOKEN;
my $TIMEZONE = "Europe/Moscow";
my $ALWAYS_NOTIFY;

# ICS parser
my $now = DateTime->now();
my $cal;
sub parse_ics_file {
    my $cal_new;
    eval {
        local *STDERR;
        open STDERR, ">", \$@;
        if ($FILENAME eq "-") {
            my $data = join "", <STDIN>;
            # Dirty hack to process Europe/Moscow timezone
            $data =~ s/(?<=UNTIL=)(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z/DateTime->new(year => $1, month => $2, day => $3, hour => $4, minute => $5, second => $6, time_zone => "UTC")->add(hours => 3)->strftime("%Y%m%dT%H%M%SZ")/esg;
            $cal_new = Data::ICal->new(data => $data);
        } elsif ($FILENAME =~ m,^https?://\S+$,s) {
            my $response;
            my $tries = 5;
            eval {
                while (not defined $response and --$tries > 0) {
                    my $res = LWP::UserAgent->new->get($FILENAME);
                    $response = $res->content unless $res->code >= 300;
                    sleep 3 + 3 * rand() unless defined $response;
                }
                1;
            } or do {
                die "LWP error: $@ : $!";
            };
            # Dirty hack to process Europe/Moscow timezone
            $response =~ s/(?<=UNTIL=)(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z/DateTime->new(year => $1, month => $2, day => $3, hour => $4, minute => $5, second => $6, time_zone => "UTC")->add(hours => 3)->strftime("%Y%m%dT%H%M%SZ")/esg;
            $cal_new = Data::ICal->new(data => $response);
        } else {
            $cal_new = Data::ICal->new(filename => $FILENAME);
        }
        die $! unless $cal_new;
        $cal = $cal_new;
    };
    unless ($cal_new) {
        warn "> $@ : $!" if $ENV{DEBUG};
        # Silently drop invalid data
        exit 0;
    }
}

# Create DateTime span object
sub get_span {
    my $delta = shift // 0;
    my $epoch = time + $delta;
    $epoch = Time::Piece->strptime($DATE => "%F")->epoch if $DATE;
    my $s = DateTime->from_epoch(epoch => $epoch)->set_time_zone($TIMEZONE)->truncate(to => 'day');
    my $e = $s->clone->add(days => 1)->subtract(seconds => 1);
    DateTime::Span->from_datetimes(start => $s, end => $e);
}

# Format zoom url
sub zoom_url {
    my ($text, $href) = @_;
    $text =~ s/(.{4}(?!.{3}$)|.{3})(?=(.{3,4})+$)/$1 /gs;
    "<b>Zoom:</b> <a href=\"$href\">$text</a>";
}

# Format talk url
sub talk_url {
    my ($text, $href) = @_;
    $text =~ s/(.{4}(?!.{3}$)|.{3})(?=(.{3,4})+$)/$1 /gs;
    "<b>Talk:</b> <a href=\"$href\">$text</a>";
}

# Format vmost url
sub vmost_url {
    my ($text, $href) = @_;
    "<b>VideoMost:</b> <a href=\"$href\">$text</a>";
}

# Format jazz url
sub jazz_url {
    my ($text, $href) = @_;
    "<b>Jazz:</b> <a href=\"$href\">$text</a>";
}

# Format webinar url
sub webinar_url {
    my ($text, $href) = @_;
    "<b>Webinar:</b> <a href=\"$href\">$text</a>";
}

# Format an event
sub format_event {
    my $e = shift // $_;
    my @msg;
    push @msg, sprintf "<b>%s:</b> <code>%s</code>", $e->{time}, $e->{summary};

    push @msg, "<b>Location:</b> $e->{location} " if length $e->{location};

    if (length($e->{url})) {
        my $url = $e->{url};
        $url = zoom_url($1, $e->{url}) if $url =~ m@/zoom.*?(\d{7,})(?:\?|$)@s;
        $url = talk_url($1, $e->{url}) if $url =~ m@/talk.*?(\d{7,})(?:\?|$)@s;
        $url = vmost_url($1, $e->{url}) if $url =~ m@confid=(\d{2,})@s;
        $url = jazz_url($1, $e->{url}) if $url =~ m@jazz.sber.ru/([^\@?\n]+)@s;
        $url = webinar_url($1, $e->{url}) if $url =~ m@events.webinar.ru/([^\@?\n]+)@s;
        push @msg, $url if $url;
    }

    push @msg, "<b>Password:</b> $e->{password} " if length $e->{password};

    return join "\n", @msg, "";
}

# Format events for cerain day
sub format_day {
    join "\n", map { format_event } events(@_);
}

# Format events for next X minutes
sub format_minutes {
    join "\n", map { format_event } filter_next_minutes_event(@_);
}

# Escape html-sensitive characters
sub html_escape {
    join "", map { s/&/&amp;/g; s/>/&gt;/g; s/</&lt;/g; $_ } @_;
}

# Extract useful events info from calendar
sub events {
    my %seen; # to remove duplicates by UID
    map {
        my ($evt, $e) = $_;

        $e->{summary} = html_escape(decode_utf8($evt->summary));
        $e->{time} = join " -- ", map { sprintf("%02d:%02d", $evt->$_->hour, $evt->$_->minute) } qw( start end );
        $e->{start} = $evt->start;

        my $url = "";
        my $password = "";
        my $location = $evt->property('location');
        $location = defined $location ? decode_utf8($location->[0]->decoded_value) : "";
        my $description = decode_utf8($evt->description);
        if ($location =~ s@(https?://\S+)@@) {
            # If there is a URL in location, use it
            $url = $1;
        } else {
            # Otherwise try to extract URL from description, but only with zoom domain
            $url = $1 if $description =~ m@(https?://(?:jazz|vmost|\S+zoom|talk|events.webinar.ru)[^<\s>]+)@s;
        }
        $location =~ s/^[.,;:\s]*//; $location =~ s/[.,;:\s-]*$//;

        # Try to extract passcode from description if url contains ?pwd= (zoom)
        if ($url =~ m@(\d+)\?pwd=@) {
            my $mid = $1;
            $mid = join "\\s?", split "", $mid;
            $mid = ":\\s+$mid";
            $mid .= "[^:]*?: (\\S+)";

            $password = $1 if $description =~ m@$mid@s;
        }

        # Try to extract passcode from description if url contains confpass= (videomost)
        if ($url =~ m@confpass=([^&]+?)$@m) {
            $password = $1;
        }

        # Try to extract passcode from description if url contains ?psw= (jazz)
        if ($url =~ m@([^/]+)\?psw=@) {
            $description =~ s/<mailto:[^>]+>//g;
            my $mid = $1;
            $mid = ":\\s+$mid";
            $mid .= "[^:]*?: (\\S+)";

            $password = $1 if $description =~ m@$mid@s;
        }

        $url =~ s/[;\s]*$//;

        $e->{location} = html_escape($location);
        $e->{url} = html_escape($url);
        $e->{password} = $password;

        $e;
    } map { my $uid = $_->uid; defined $uid ? ( $seen{$uid}++ ? () : $_ ) : $_ }
    sort { DateTime->compare(map { $_->start } ($a, $b)) } $cal->events(get_span(@_), 'day');
}

# Find events in next X minutes
sub filter_next_minutes_event {
    my $minutes = shift // 30;

    my $s = DateTime->from_epoch(epoch => time)->truncate(to => 'minute');
    my $e = $s->clone->add(minutes => $minutes);
    my $span = DateTime::Span->from_datetimes(start => $s, end => $e);
    $span->set_time_zone($TIMEZONE);

    grep { $span->intersects($_->{start}) } events(@_);
}

# Send telegram message
sub notify {
    my $text = shift;
    return unless $text;
    warn "Sending notification:\n$text" if $ENV{DEBUG};
    WWW::Telegram::BotAPI->new(token => $TOKEN)->sendMessage({
        chat_id => $CHATID,
        text => $text,
        disable_web_page_preview => 1,
        parse_mode => 'html',
    });
}

# Handlers for -day option
my %day_handlers = (
    date => sub {
        parse_ics_file();
        my $events = format_day();
        if ($events) {
            notify("<b>On $DATE:</b>\n\n$events");
        } elsif ($ALWAYS_NOTIFY) {
            notify("<b>Nothing \x{1F9D9}</b>\n\n$events");
        }
    },
    today => sub {
        parse_ics_file();
        my $events = format_day();
        if ($events) {
            notify("<b>Today:</b>\n\n$events");
        } elsif ($ALWAYS_NOTIFY) {
            notify("<b>Nothing \x{1F9D9}</b>\n\n$events");
        }
    },
    tomorrow => sub {
        parse_ics_file();
        my $events = format_day(1 * 24 * 3600);
        if ($events) {
            notify("<b>Tomorrow:</b>\n\n$events");
        } elsif ($ALWAYS_NOTIFY) {
            notify("<b>Nothing \x{1F9D9}</b>\n\n$events");
        }
    },
    monday => sub {
        parse_ics_file();
        my $events = format_day(3 * 24 * 3600);
        if ($events) {
            notify("<b>Monday:</b>\n\n$events");
        } elsif ($ALWAYS_NOTIFY) {
            notify("<b>Nothing \x{1F9D9}</b>\n\n$events");
        }
    },
    next => sub {
        parse_ics_file();
        my $events = format_minutes(8 * 60);
        if ($events) {
            notify("<b>Events in next 8 hours:</b>\n\n$events");
        } else {
            notify("<b>Nothing in next 8 hours \x{1F37A}</b>");
        }
    },
);

# Get options
GetOptions(
    "always" => \$ALWAYS_NOTIFY,
    "chatid=s" => \$CHATID,
    "day=s" => \$DAY,
    "date=s" => \$DATE,
    "file=s" => \$FILENAME,
    "timezone=s" => \$TIMEZONE,
    "token=s" => \$TOKEN,
) or die "Error in arguments!";

# Validate options
die "Unknown options specified: @ARGV" if @ARGV;
$DAY = lc($DAY);
die "Invalid value for Day" if $DAY and not defined $day_handlers{$DAY};
die "Date is not specified" if $DAY eq "date" and not defined $DATE;
die "ChatID cannot be empty" unless $CHATID;
die "Token cannot be empty" unless $TOKEN;

# Execute -day handlers, if any
if ($DAY) {
    $day_handlers{$DAY}->();
    exit 0;
}

# Parse the file
parse_ics_file();

# By default notify for any soon events
my $events = format_minutes(2);
notify($events) if $events;
