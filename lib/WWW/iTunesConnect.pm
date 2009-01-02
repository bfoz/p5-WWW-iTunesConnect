# Filename: iTunesConnect.pm
#
# iTunes Connect client interface
#
# Copyright 2008 Brandon Fosdick <bfoz@bfoz.net> (BSD License)
#
# $Id: iTunesConnect.pm,v 1.8 2009/01/02 05:41:05 bfoz Exp $

package WWW::iTunesConnect;

use strict;
use warnings;
use vars qw($VERSION);

$VERSION = sprintf("%d.%03d", q$Revision: 1.8 $ =~ /(\d+)\.(\d+)/);

use LWP;
use HTML::Form;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

use constant URL_PHOBOS => 'https://phobos.apple.com';

# --- Constructor ---

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

# --- Class Methods ---

# Parse a gzip'd summary file fetched from the Sales/Trend page
#  First argument is same as input argument to gunzip constructor
#  Remaining arguments are passed as options to gunzip
sub parse_sales_summary
{
    my ($input, %options) = @_;

# gunzip the data into a scalar
    my $content;
    my $status = gunzip $input => \$content;
    return $status unless $status;

# Parse the data into a hash of arrays
    my @content = split /\n/,$content;
    my @header = split /\t/, shift(@content);
    my @data;
    for( @content )
    {
        my @a = split /\t/;
        push @data, \@a;
    }

    ('header', \@header, 'data', \@data);
}

# --- Instance Methods ---

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
    return undef unless $form;
# Pull the available dates out of the form's select input
    my $input = $form->find_input('9.11.1', 'option');
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
	return undef unless $date;
    }

# Get an HTML::Form object for the Sales/Trends Reports Daily Summary page
    my $form = $s->daily_sales_summary_form();
# Submit the form to get the latest daily summary
    $form->value('9.7', 'Summary');
    $form->value('9.9', 'Daily');
    $form->value('9.11.1', $date);
    $form->value('hiddenDayOrWeekSelection', $date);
    $form->value('hiddenSubmitTypeName', 'Download');
    $form->value('download', 'Download');
# Fetch the summary
    my $r = $s->{ua}->request($form->click('download'));
    return undef unless $r;
    my $filename =  $r->header('Content-Disposition');
    $filename = (split(/=/, $filename))[1] if $filename;

    (parse_sales_summary(\$r->content), 'file', $r->content, 'filename', $filename);
}

# Fetch the list of available dates for Sales/Trend Monthly Summary Reports. This
#  caches the returned results so it can be safely called multiple times.
sub monthly_free_summary_dates
{
    my $s = shift;

# Get an HTML::Form object for the Sales/Trends Reports Monthly Summary page
    my $form = $s->monthly_free_summary_form();
    return undef unless $form;
# Pull the available date ranges out of the form's select input
    my $input = $form->find_input('9.14.1', 'option');
    return undef unless $input;
# Parse the strings into an array of hash references
    my @dates;
    push @dates, {'From', split(/ /, $_)} for $input->value_names;
# Sort and return the date ranges
    sort { $b->{To} cmp $a->{To} } @dates;
}

sub monthly_free_summary
{
    my $s = shift;
    my (%options) = @_ if scalar @_;

    return undef if %options and $options{To} and $options{From} and 
	(($options{To} !~ /\d{2}\/\d{2}\/\d{4}/) or 
	($options{From} !~ /\d{2}\/\d{2}\/\d{4}/));
    unless( %options )
    {
        # Get the list of available dates
        my @months = $s->monthly_free_summary_dates();
	return undef unless @months;
        # The list is sorted in descending order, so most recent is first
        %options = %{shift @months};
    }

# Munge the date range into the format used by the form
    $options{To} =~ /(\d{2})\/(\d{2})\/(\d{4})/;
    my $to = $3.$1.$2;
    $options{From} =~ /(\d{2})\/(\d{2})\/(\d{4})/;
    my $month = $3.$1.$2.'#'.$to;

# Get an HTML::Form object for the Sales/Trends Reports Daily Summary page
    my $form = $s->monthly_free_summary_form();
# Submit the form to get the latest weekly summary
    $form->value('9.7', 'Summary');
    $form->value('9.9', 'Monthly Free');
    $form->value('9.14.1', $month);
    $form->value('hiddenDayOrWeekSelection', $month);
    $form->value('hiddenSubmitTypeName', 'Download');
    $form->value('download', 'Download');
# Fetch the summary
    my $r = $s->{ua}->request($form->click('download'));
    return undef unless $r;
# If a given month is actually empty, the download will return the same page 
#  with a notice to the user. Check for the notice and bail out if found.
    return undef unless index($r->as_string, 'There are no free transactions to report') == -1;

    my $filename =  $r->header('Content-Disposition');
    $filename = (split(/=/, $filename))[1] if $filename;

    (parse_sales_summary(\$r->content), 'file', $r->content, 'filename', $filename);
}

# Fetch the list of available dates for Sales/Trend Weekly Summary Reports. This
#  caches the returned results so it can be safely called multiple times.
sub weekly_sales_summary_dates
{
    my $s = shift;

# Get an HTML::Form object for the Sales/Trends Reports Weekly Summary page
    my $form = $s->weekly_sales_summary_form();
    return undef unless $form;
# Pull the available date ranges out of the form's select input
    my $input = $form->find_input('9.13.1', 'option');
    return undef unless $input;
# Parse the strings into an array of hash references
    my @dates;
    push @dates, {'From', split(/ /, $_)} for $input->value_names;
# Sort and return the date ranges
    sort { $b->{To} cmp $a->{To} } @dates;
}

sub weekly_sales_summary
{
    my $s = shift;
    my $week = shift if scalar @_;

    return undef if $week and ($week !~ /\d{2}\/\d{2}\/\d{4}/);
    unless( $week )
    {
        # Get the list of available dates
        my @weeks = $s->weekly_sales_summary_dates();
	return undef unless @weeks;
        # The list is sorted in descending order, so most recent is first
        $week = shift @weeks;
	$week = $week->{To};
    }

# Get an HTML::Form object for the Sales/Trends Reports Daily Summary page
    my $form = $s->weekly_sales_summary_form();
# Submit the form to get the latest weekly summary
    $form->value('9.7', 'Summary');
    $form->value('9.9', 'Weekly');
    $form->value('9.13.1', $week);
    $form->value('hiddenDayOrWeekSelection', $week);
    $form->value('hiddenSubmitTypeName', 'Download');
    $form->value('download', 'Download');
# Fetch the summary
    my $r = $s->{ua}->request($form->click('download'));
    return undef unless $r;
    my $filename =  $r->header('Content-Disposition');
    $filename = (split(/=/, $filename))[1] if $filename;

    (parse_sales_summary(\$r->content), 'file', $r->content, 'filename', $filename);
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
        return undef unless $form;
        $form->value('9.7', 'Summary');
        $form->value('9.9', 'Daily');
        $form->value('hiddenSubmitTypeName', 'ShowDropDown');
        my $r = $s->{ua}->request($form->click('download'));
        $s->{daily_summary_sales_response} = $r;
    }

# The response includes a form containing a select input element with the list 
#  of available dates. Create and return a form object for it.
    my @forms = HTML::Form->parse($s->{daily_summary_sales_response});
    @forms = grep $_->attr('name') eq 'frmVendorPage', @forms;
    return undef unless @forms;
    shift @forms;
}

# Use the Sales/Trend Reports form to get a form for fetching monthly summaries
sub monthly_free_summary_form
{
    my ($s) = @_;

# Use cached response to avoid another trip on the net
    unless( $s->{monthly_summary_free_response} )
    {
# Get an HTML::Form object for the Sales/Trends Reports page. Then fill it out
#  and submit it to get a list of available Monthly Summary dates.
        my $form = $s->sales_form();
        return undef unless $form;
        $form->value('9.7', 'Summary');
        $form->value('9.9', 'Monthly Free');
        $form->value('hiddenSubmitTypeName', 'ShowDropDown');
        my $r = $s->{ua}->request($form->click('download'));
        $s->{monthly_summary_free_response} = $r;
    }

# The response includes a form containing a select input element with the list 
#  of available dates. Create and return a form object for it.
    my @forms = HTML::Form->parse($s->{monthly_summary_free_response});
    @forms = grep $_->attr('name') eq 'frmVendorPage', @forms;
    return undef unless @forms;
    shift @forms;
}

# Use the Sales/Trend Reports form to get a form for fetching weekly summaries
sub weekly_sales_summary_form
{
    my ($s) = @_;

# Use cached response to avoid another trip on the net
    unless( $s->{weekly_summary_sales_response} )
    {
# Get an HTML::Form object for the Sales/Trends Reports page. Then fill it out
#  and submit it to get a list of available Weekly Summary dates.
        my $form = $s->sales_form();
        return undef unless $form;
        $form->value('9.7', 'Summary');
        $form->value('9.9', 'Weekly');
        $form->value('hiddenSubmitTypeName', 'ShowDropDown');
        my $r = $s->{ua}->request($form->click('download'));
        $s->{weekly_summary_sales_response} = $r;
    }

# The response includes a form containing a select input element with the list 
#  of available dates. Create and return a form object for it.
    my @forms = HTML::Form->parse($s->{weekly_summary_sales_response});
    @forms = grep $_->attr('name') eq 'frmVendorPage', @forms;
    return undef unless @forms;
    shift @forms;
}

# Generate an HTML::Form from the cached Sales/Trend Reports page
sub sales_form
{
    my $s = shift;

# Fetch the Sales/Trend Report page
    my $r = $s->sales_response();
    return undef unless $r;

    my @forms = HTML::Form->parse($r);
    @forms = grep $_->attr('name') eq 'frmVendorPage', @forms;
    return undef unless @forms;
    shift @forms;
}

# Follow the Sales/Trend Reports redirect and store the response for later use
sub sales_response
{
    my $s = shift;

# Returned cached response to avoid another trip on the net
    return $s->{sales_response} if $s->{sales_response};

# Check for a valid login
    return undef unless $s->login;

# Handle the Sales/Trend Reports redirect 
    my $r = $s->request($s->{sales_path});
    $r->as_string =~ /<META HTTP-EQUIV="refresh" Content="0;URL=(.*)">/;
    $r = $s->{ua}->get($1);
# The redirect asks for the user info again
    my @forms = HTML::Form->parse($r);
    return undef unless @forms;
    my $form = shift @forms;	# Only one form on the page
    $form->value('theAccountName', $s->{user});
    $form->value('theAccountPW', $s->{password});
    $r = $s->{ua}->request($form->click('1.Continue'));
    return undef unless $r;
    $s->{sales_response} = $r;
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

=item $itc = WWW::iTunesConnect->new(user=>$user, password=>$password);

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

=head1 Class Methods

=item %report = WWW::iTunesConnect->parse_sales_summary($input, %options)

Parse a gzip'd summary file fetched from the Sales/Trend page. Arguments are 
the same as the L<IO::Uncompress::Gunzip> constructor, less the output argument.
To parse a file pass a scalar containing the file name as $input. To parse a 
string of content, pass a scalar reference as $input. The %options hash is 
passed directly to I<gunzip>.

The returned hash has two elements: I<header> and I<data>. The I<header> element 
is a reference to an array of the column headers in the fetched TSV file. The 
I<data> element is a reference to an array of array references, one for each 
non-header line in the fetched TSV file.

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
hash of array references. The returned hash has two elements in addition to the 
elements returned by I<parse_sales_summary>: I<file> and I<filename>. The 
I<file> element is the raw content of the file retrieved from iTunes Connect 
and the I<filename> element is the filename provided by the Content-Disposition 
header line.

If a single string argument is given in the form 'MM/DD/YYYY' that date will be
fetched instead (if it's available).

=item $itc->monthly_free_summary_dates

Fetch the list of available months for Sales/Trend Monthly Summary Reports. This
caches the returned results so it can be safely called multiple times.

Months are returned as an array of hash references in descending order. Each 
hash contains the keys I<From> and I<To>, indicating the start and end dates of 
each report.

=item $itc->monthly_free_summary( %options )

Fetch the most recent Sales/Trends Monthly Summary report and return it as a
hash of array references. The returned hash has two elements in addition to the 
elements returned by I<parse_sales_summary>: I<file> and I<filename>. The 
I<file> element is the raw content of the file retrieved from iTunes Connect 
and the I<filename> element is the filename provided by the Content-Disposition 
header line.

If both I<From> and I<To> options are passed, and both are of the form 
'MM/DD/YYYY', the monthly summary matching the two dates will be fetched 
instead (if it's available). The hashes returned by monthly_free_summary_dates()
are suitable for passing to this method.

=item $itc->weekly_sales_summary_dates

Fetch the list of available dates for Sales/Trend Weekly Summary Reports. This
caches the returned results so it can be safely called multiple times.

Dates are sorted in descending order.

=item $itc->weekly_sales_summary()

Fetch the most recent Sales/Trends Weekly Summary report and return it as a
hash of array references. The returned hash has two elements in addition to the 
elements returned by I<parse_sales_summary>: I<file> and I<filename>. The 
I<file> element is the raw content of the file retrieved from iTunes Connect 
and the I<filename> element is the filename provided by the Content-Disposition 
header line.

If a single string argument is given in the form 'MM/DD/YYYY' the week ending 
on the given date will be fetched instead (if it's available).

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
