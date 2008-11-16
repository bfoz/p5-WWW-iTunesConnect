# Filename: iTunesConnect.pm
#
# iTunes Connect client interface
#
# Copyright 2008 Brandon Fosdick <bfoz@bfoz.net> (BSD License)
#
# $Id: iTunesConnect.pm,v 1.3 2008/11/16 04:33:23 bfoz Exp $

package WWW::iTunesConnect;

use strict;
use warnings;
use vars qw($VERSION);

$VERSION = sprintf("%d.%03d", q$Revision: 1.3 $ =~ /(\d+)\.(\d+)/);

use LWP;
use HTML::Form;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

use constant URL_PHOBOS => 'https://phobos.apple.com';

sub new
{
    my ($this, %options) = @_;
    my $class = ref($this) || $this;
    my $self = {};
    bless $self, $class;

    $self->{user} = $options{user} if $options{user};
    $self->{password} = $options{password} if $options{password};

    $self->{ua} = LWP::UserAgent->new(%options);
    $self->{ua}->cookie_jar({});

    return $self;
}

sub login
{
    my $s = shift;

# Bail out if no username and password
    return undef unless $s->{user} and $s->{password};
# Prevent repeat logins
    return 1 if $s->{sales_path} and $s->{financial_path};

# Fetch the login page
    my $r = $s->request('/WebObjects/MZLabel.woa/wa/default');
    return undef unless $r;
# Pull out the path for submitting user credentials
    $r->as_string =~ /<form.*name=.*action="(.*)">/;
#    $s->{login_url} = $1;
# Submit the user's credentials
    $r = $s->request($1.'?theAccountName='.$s->{user}.'&theAccountPW='.$s->{password}.'&theAuxValue=');
    return undef unless $r;
# Find the Sales/Trend Reports path and save it for later
    $r->as_string =~ /href="(.*)">\s*\n\s*<b>Sales\/Trend Reports<\/b>/;
    $s->{sales_path} = $1;
# Find the Financial Reports path and save it for later
    $r->as_string =~ /href="(.*)">\s*\n\s*<b>Financial Reports<\/b>/;
    $s->{financial_path} = $1;
    1;
}

sub financial_report
{
    my $s = shift;

# Check for a valid login
    return undef unless $s->login;

# Fetch the Financial Reports page
    my $r = $s->request($s->{sales_path});
    return undef unless $r;
# Generate forms
    my @forms = HTML::Form->parse($r);
# Find the desired form
    @forms = grep $_->attr('name') eq 'f_0_0_5_1_5_1_1_2_3', @forms;
    return undef unless @forms;
    my $form = shift @forms;
# Get the most recent report
# Parse and return
}

# Fetch the list of available dates for Sales/Trend Daily Summary Reports. This
#  caches the returned results so it can be safely called multiple times. Note, 
#  however, that if the parent script runs for longer than 24 hours the cached
#  results will be invalid. The cached results may become invalid sooner.
sub daily_sales_summary_dates
{
    my $s = shift;

# Get an HTML::Form object for the Sales/Trends Reports Daily Summary page
    my $form = $s->daily_sales_summary_form();
# Pull the available dates out of the form's select input
    my $input = $form->find_input('9.9.1', 'option');
    return undef unless $input;
# Sort and return the dates
    sort { $b cmp $a } $input->possible_values;
}

sub daily_sales_summary
{
    my $s = shift;
    my $date = shift if scalar @_;

    return undef if $date and ($date !~ /\d{2}\/\d{2}\/\d{4}/);
    unless( $date )
    {
        # Get the list of available dates
        my @dates = $s->daily_sales_summary_dates();
        # The list is sorted in descending order, so most recent is first
        $date = shift @dates;
    }

# Get an HTML::Form object for the Sales/Trends Reports Daily Summary page
    my $form = $s->daily_sales_summary_form();
# Submit the form to get the latest daily summary
    $form->value('9.5', 'Summary');
    $form->value('9.7', 'Daily');
    $form->value('9.9.1', $date);
    $form->value('hiddenDayOrWeekSelection', $date);
    $form->value('hiddenSubmitTypeName', 'Download');
    $form->value('download', 'Download');
# Fetch the summary
    my $r = $s->{ua}->request($form->click('download'));
    return undef unless $r;
    my $filename =  $r->header('Content-Disposition');
    $filename = (split(/=/, $filename))[1] if $filename;
# gunzip the data
    my $content;
    my $input = $r->content;
    gunzip \$input => \$content or die "gunzip failed: $GunzipError\n";
# Parse the data into a hash of arrays
    my @content = split /\n/,$content;
    my @header = split /\t/, shift(@content);
    my @data;
    for( @content )
    {
        my @a = split /\t/;
        push @data, \@a;
    }

    ('header', \@header, 'data', \@data, 'file', $input, 'filename', $filename);
}

# --- Getters and Setters ---

sub user
{
    my $s = shift;
    $s->{user} = shift if scalar @_;
    $s->{user};
}

sub password
{
    my $s = shift;
    $s->{password} = shift if scalar @_;
    $s->{password};
}

# Use the Sales/Trend Reports form to get a form for fetching daily summaries
sub daily_sales_summary_form
{
    my ($s) = @_;

# Use cached response to avoid another trip on the net
    unless( $s->{daily_summary_sales_response} )
    {
# Get an HTML::Form object for the Sales/Trends Reports page. Then fill it out
#  and submit it to get a list of available Daily Summary dates.
        my $form = $s->sales_form();
        $form->value('9.5', 'Summary');
        $form->value('9.7', 'Daily');
        $form->value('hiddenSubmitTypeName', 'ShowDropDown');
        my $r = $s->{ua}->request($form->click('download'));
        $s->{daily_summary_sales_response} = $r;
    }

# Pull the date list out of the returned form object
    my @forms = HTML::Form->parse($s->{daily_summary_sales_response});
    @forms = grep $_->attr('name') eq 'frmVendorPage', @forms;
    return undef unless @forms;
    shift @forms;
}

# Generate an HTML::Form from the cached Sales/Trend Reports page
sub sales_form
{
    my $s = shift;

# Fetch the Sales/Trend Report page
    my $r = $s->sales_reponse();
    return undef unless $r;

    my @forms = HTML::Form->parse($r);
    @forms = grep $_->attr('name') eq 'frmVendorPage', @forms;
    return undef unless @forms;
    shift @forms;
}

# Follow the Sales/Trend Reports redirect and store the response for later use
sub sales_reponse
{
    my $s = shift;

# Returned cached response to avoid another trip on the net
    return $s->{sales_reponse} if $s->{sales_reponse};

# Check for a valid login
    return undef unless $s->login;

# Handle the Sales/Trend Reports redirect 
    my $r = $s->request($s->{sales_path});
    $r->as_string =~ /<META HTTP-EQUIV="refresh" Content="0;URL=(.*)">/;
    $r = $s->{ua}->get($1);
    $s->{sales_reponse} = $r;
}

# --- Internal use only ---

sub request
{
    my ($s, $url) = @_;
    return undef unless $s->{ua};
    return $s->{ua}->get(URL_PHOBOS.$url);
}

1;

=head1 NAME

iTunesConnect - An iTunesConnect client interface

=head1 SYNOPSIS

 use WWW::iTunesConnect;

 my $itc = WWW::iTunesConnect->new(user=>$user, password=>$password);
 my %report = $itc->daily_sales_summary;

=head1 DESCRIPTION

C<iTunesConnect> provides an interface to Apple's iTunes Connect website.
For now only the previous day's daily sales summary can be retrieved. This is 
just a quick first cut that I whipped up to avoid losing any data. Eventually 
this will be a complete interface.

=head1 CONSTRUCTOR

=over

=item $itc = iTunesConnect->new;

Constructs and returns a new C<iTunesConnect> interface object. Accepts a hash
containing the iTunes Connect username and password.

=back

=head1 ATTRIBUTES

=over

=item $itc->user

Get/Set the iTunes Connect username. NOTE: User and Password must be set 
before calling any other methods.

=item $itc->password

Get/Set the iTunes Connect password. NOTE: User and Password must be set 
before calling any other methods.

=back

=head1 METHODS

These methods fetch various bits of information from the iTunes Connect servers.
Everything here uses LWP and is therefore essentially a screen scraper. So, be
careful and try not to load up Apple's servers too much. We don't want them to
make this any more difficult than it already is.

=over

=item $itc->login()

Uses the username and password properties to authenticate to the iTunes Connect
server. This is automatically called as needed by the other fetch methods if 
user and password have already been set.

=item $itc->daily_sales_summary_dates

Fetch the list of available dates for Sales/Trend Daily Summary Reports. This
caches the returned results so it can be safely called multiple times. Note, 
however, that if the parent script runs for longer than 24 hours the cached
results will be invalid.

Dates are sorted in descending order.

=item $itc->daily_sales_summary()

Fetch the most recent Sales/Trends Daily Summary report and return it as a
hash of array references. The returned hash has four elements: I<header>, 
I<data>, I<file> and I<filename>. The I<header> element is an array of the 
column headers in the fetched TSV file. The I<data> element is an array of 
array references, one for each non-header line in the fetched TSV file. The 
I<file> element is the raw content of the file retrieved from iTunes Connect 
and the I<filename> element is the filename provided by the Content-Disposition 
header line.

If a single string argument is given in the form 'MM/DD/YYYY' that date will be
fetched instead (if it's available).

=back

=head1 SEE ALSO

L<LWP>
L<HTML::Form>
L<IO::Uncompress::Gunzip>
L<Net::SSLeay>

=head1 AUTHOR

Brandon Fosdick, E<lt>bfoz@bfoz.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2008 Brandon Fosdick <bfoz@bfoz.net>

This software is provided under the terms of the BSD License.

=cut
