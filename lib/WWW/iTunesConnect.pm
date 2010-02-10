# Filename: iTunesConnect.pm
#
# iTunes Connect client interface
#
# Copyright 2008-2009 Brandon Fosdick <bfoz@bfoz.net> (BSD License)
#
# $Id: iTunesConnect.pm,v 1.12 2009/01/22 05:23:57 bfoz Exp $

package WWW::iTunesConnect;

use strict;
use warnings;
use vars qw($VERSION);

$VERSION = "1.14";

use LWP;
use HTML::Form;
use HTML::TreeBuilder;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

use constant URL_PHOBOS => 'https://phobos.apple.com';
use constant MONTH_2_NUM => { 'Jan' => '01', 'Feb' => '02', 'Mar' => '03', 'Apr' => '04',
                              'May' => '05', 'Jun' => '06', 'Jul' => '07', 'Aug' => '08',
                              'Sep' => '09', 'Oct' => '10', 'Nov' => '11', 'Dec' => '12' };

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
    # Allow POST requests to be redirected because some of the international
    #  iTC mirrors redirect various requests
    push @{ $self->{ua}->requests_redirectable}, 'POST';

    return $self;
}

# --- Class Methods ---

# Parse a TSV data table retrieved from iTunes Connect
sub parse_table
{
    my ($content) = @_;

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

# Parse the data into a hash of array refs and return
    parse_table($content);
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
    return undef unless $1;
# Submit the user's credentials
    $r = $s->request($1.'?theAccountName='.$s->{user}.'&theAccountPW='.$s->{password}.'&theAuxValue=');
    return undef unless $r;
# Find the Sales/Trend Reports path and save it for later
    $r->as_string =~ /href="(.*)">\s*\n\s*<b>Sales and Trends<\/b>/;
    $s->{sales_path} = $1;
# Find the Financial Reports path and save it for later
    $r->as_string =~ /href="(.*)">\s*\n\s*<b>Financial Reports<\/b>/;
    $s->{financial_path} = $1;
    1;
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
    my $input = $form->find_input('#dayorweekdropdown', 'option');
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
    return undef unless $form;
# Submit the form to get the latest daily summary
    $form->value('#selReportType', 'Summary');
    $form->value('#selDateType', 'Daily');
    $form->value('#dayorweekdropdown', $date);
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

# Fetch the list of available financial reports
sub financial_report_list
{
    my $s = shift;

# Return cached list to avoid another trip on the net
    return $s->{financial_reports} if $s->{financial_reports};

# Check for a valid login
    return undef unless $s->login;

# Fetch the Financial Reports page
    my $r = $s->request($s->{financial_path});
    return undef unless $r;

# Get the Items/Page form and set to display the max number of reports
    my @forms = HTML::Form->parse($r);
    @forms = grep $_->find_input('itemsPerPage', 'text'), @forms;
    my $form = shift @forms;
    return undef unless $form;

    # Parse the input's label to find the highest value that it can be set to
    $r->as_string =~ /items\/page \(max (\d+)\)/;
    $form->value('itemsPerPage', $1);
    $r = $s->{ua}->request($form->click);
    return undef unless $r;

# Parse the page into a tree
    my $tree = HTML::TreeBuilder->new_from_content($r->as_string);

    # Get the table by address (because there's nothing unique about it) and then get all child rows
    my @rows = $tree->address('0.1.2.0.0.0.3.1.1')->look_down('_tag','tr');
    # The first 3 rows are headers, etc so get rid of them
    @rows = @rows[3..$#rows];

# Parse the list of reports
    my %reports;
    for( @rows )
    {
	my @cols = $_->look_down('_tag','td');
	$cols[0]->as_trimmed_text =~ /([A-Z][a-z]{2})\s+(\d{4})/;
	my $date = $2.MONTH_2_NUM->{$1};
	my $region = $cols[1]->as_trimmed_text;
	my $a = scalar $cols[2]->look_down('_tag','a');
	@{$reports{$date}{$region}}{qw(path filename)} = ($a->attr('href'), $a->as_trimmed_text);
    }

# Save the list for later and return
    $s->{financial_reports} = \%reports;
}

sub financial_report
{
    my $s = shift;
    my $date = shift if scalar @_;
    return undef if $date and ($date !~ /\d{4}\d{2}/);

# Get the list of available reports
    my %reports = %{$s->financial_report_list()};

# Get the most recent month's reports if no month was given
    unless( $date )
    {
	my @dates = sort { $b <=> $a } keys %reports;
	$date = shift @dates;
	return undef unless $date;
    }

# Fetch the reports for either the given month or the most recent month available    
    my $regions = $reports{$date};
    my %out;
    for( keys %{$regions} )
    {
	my $r = $s->request($regions->{$_}{path});
	next unless $r;

	# Parse the data
	my %table = parse_table($r->content);
	my ($header, $data) = @table{qw(header data)};

	# Strip off the Total row and parse it
	my @total = grep {$_ && length $_} @{$data->[-1]};
	@total = undef unless shift(@total) eq 'Total';
	if( @total )
	{
	    pop @$data;  # Remove the Total row from the data
	    pop @$data;  # Discard the blank row
	}

	# Convert the various region-specific date formats to YYYYMMDD
	my $startIndex = 0;
	my $endIndex = 0;
	++$startIndex while $header->[$startIndex] ne 'Start Date';
	++$endIndex while $header->[$endIndex] ne 'End Date';
	my $eu_reg = qr/(\d\d)\.(\d\d)\.(\d{4})/;
	my $us_reg = qr/(\d\d)\/(\d\d)\/(\d{4})/;
	for( @$data )
	{
	    if( @$_[$startIndex] =~ $eu_reg )       # EU format
	    {
		@$_[$startIndex] = $3.$2.$1;
		@$_[$endIndex] =~ $eu_reg;
		@$_[$endIndex] = $3.$2.$1;
	    }
	    elsif( @$_[$startIndex] =~ $us_reg )    # US format
	    {
		@$_[$startIndex] = $3.$1.$2;
		@$_[$endIndex] =~ $us_reg;
		@$_[$endIndex] = $3.$1.$2;
	    }
	}

	@{$out{$date}{$_}}{qw(header data file filename total currency)} = ($header, $data, $r->content, $regions->{$_}{filename}, @total);
    }
    %out;   # Return
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
    return undef unless $form;
# Submit the form to get the latest weekly summary
    $form->value('#selReportType', 'Summary');
    $form->value('#selDateType', 'Monthly Free');
    $form->value('#dayorweekdropdown', $month);
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
    my $input = $form->find_input('#dayorweekdropdown', 'option');
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
    return undef unless $form;
# Submit the form to get the latest weekly summary
    $form->value('#selReportType', 'Summary');
    $form->value('#selDateType', 'Weekly');
    $form->value('#dayorweekdropdown', $week);
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
        $form->value('#selReportType', 'Summary');
        $form->value('#selDateType', 'Daily');
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
        $form->value('#selReportType', 'Summary');
        $form->value('#selDateType', 'Monthly Free');
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
        $form->value('#selReportType', 'Summary');
        $form->value('#selDateType', 'Weekly');
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
Daily, Weekly and Monthly summaries, as well as Finanacial Reports, can be
retrieved. Eventually this will become a complete interface.

A script suitable for use as a nightly cronjob can be found at 
L<http://bfoz.net/projects/itc/>

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

=over

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

=item $itc->financial_report_list()

Fetch the list of available Financial Reports. This caches the returned results 
and can be safely called multiple times.

=item $itc->financial_report()

Fetch the most recent Financial Report and return it as a hash. The keys of the 
returned hash are of the form 'YYYYMM', each of which is a hash containing one 
entry for each region included in that month's report. Each of the region 
entries is a yet another hash with six elements:

    Key		Description
    ---------------------------------------------
    currency	Currency code
    data	Reference to array of report rows
    file	Raw content of the retrieved file
    filename	Retrieved file name
    header	Header row
    total	Sum of all rows in data

If a single string argument is given in the form 'YYYYMM', that month's report 
will be fetched instead (if it's available).

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
L<HTML::Tree>
L<IO::Uncompress::Gunzip>
L<Net::SSLeay>

=head1 AUTHOR

Brandon Fosdick, E<lt>bfoz@bfoz.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2008-2009 Brandon Fosdick <bfoz@bfoz.net>

This software is provided under the terms of the BSD License.

=cut
