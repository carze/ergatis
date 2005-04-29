#!/usr/local/bin/perl

=head1  NAME 

nap2bsml.pl - convert nap btab output to BSML

=head1 SYNOPSIS

USAGE: nap2bsml.pl 
    --input=/path/to/somefile.nap.btab 
    --output=/path/to/somefile.nap.bsml

=head1 OPTIONS

B<--input,-i> 
    Input btab file from a nap search.

B<--debug,-d> 
    Debug level.  Use a large number to turn on verbose debugging. 

B<--log,-l> 
    Log file

B<--output,-o> 
    Output BSML file

B<--help,-h> 
    This help message

=head1   DESCRIPTION

This script is used to convert the btab output from a nap search into BSML.

=head1 INPUT

The input to this component is the btab file created by the nap executable.  This file
is 19-column, tab-delimited text document.  The input can be a the nap btab output from
a single search for a concatenated file from multiple searches.  Define the input file
using the --input option.

Illegal characters will be removed from the 
IDs for the query sequence (column 0) and subject hit (column 5) if necessary to create 
legal XML id names.  For each element, the original, unmodified name will be stored in the "title"
attribute of the Sequence element.  You should make sure that your ids don't begin with
a number.  This script will successfully create a BSML document regardless of your ID names,
but the resulting document may not pass DTD validation.

=head1 OUTPUT

The BSML file to be created is defined using the --output option.  If the file already exists
it will be overwritten.

=head1 CONTACT

    Joshua Orvis
    jorvis@tigr.org

=cut

use strict;
use Log::Log4perl qw(get_logger);
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev);
use BSML::BsmlBuilder;
use BSML::BsmlReader;
use BSML::BsmlParserTwig;
use BSML::BsmlRepository;
use Pod::Usage;
use Workflow::Logger;

my %options = ();
my $results = GetOptions (\%options, 
			  'input|i=s',
              'output|o=s',
              'log|l=s',
              'debug=s',
			  'help|h') || pod2usage();

my $logfile = $options{'log'} || Workflow::Logger::get_default_logfilename();
my $logger = new Workflow::Logger('LOG_FILE'=>$logfile,
				  'LOG_LEVEL'=>$options{'debug'});
$logger = $logger->get_logger();

# display documentation
if( $options{'help'} ){
    pod2usage( {-exitval=>0, -verbose => 2, -output => \*STDOUT} );
}

## make sure all passed options are peachy
&check_parameters(\%options);

## we want a new doc
my $doc = new BSML::BsmlBuilder();

## open the input file for parsing
open (my $ifh, $options{'input'}) || $logger->logdie("can't open input file for reading");

## to allow btab files to be merged together before they are converted to BSML,
##  we can't assume that the first column will always be the qry id, even though
##  nap can only be run on one sequence.  So that we don't have to hold the entire
##  doc in memory, we'll keep each qry_id - sbj_id combination in %data along with
##  a reference to their Seq-pair-alignment.  That way we can just add Seq-pair-run
##  elements to them when necessary.
my %data;
my %seqs_found;
while (<$ifh>) {
    ## ignore whitespace lines
    next if ( /^\s*$/ );
    chomp;
    
    ## there should be 19 elements in cols, unless we have an unrecognized format.
    my @cols = split("\t");
    unless (scalar @cols == 19) {
        $logger->error("the following nap btab line was not recognized and could not be parsed (should have 19 columns, actually has " . scalar(@cols) . "):\n$_\n") if ($logger->is_error);
        next;
    }
    
    my ($qry_id, $sbj_id) = ($cols[0], $cols[5]);
    
    ## the qry ID only counts up to the first whitespace
    if ($qry_id =~ /(.+?)\s+/) {
        $qry_id = $1;
    }
    
    ## make sure both of these are valid IDs
    $qry_id =~ s/[^a-zA-Z0-9\.\-\_]/_/g;
    $sbj_id =~ s/[^a-zA-Z0-9\.\-\_]/_/g;
    
    ## has this query sequence been added to the doc yet?
    if (! exists $seqs_found{$qry_id}) {
        my $seq = $doc->createAndAddSequence($qry_id, $cols[0], undef, 'na', 'assembly');
        $seq->addBsmlLink('analysis', '#aat_aa_analysis');
        $seqs_found{$qry_id} = 1;
    }
    
    ## has this subject sequence been added to the doc yet?
    if (! exists $seqs_found{$sbj_id}) {
        my $seq = $doc->createAndAddSequence($sbj_id, $cols[5], undef, 'aa', 'protein');
        $doc->createAndAddCrossReferencesByParse( sequence => $seq, string => $cols[5]);
        $seq->addBsmlLink('analysis', '#aat_aa_analysis');
        $seqs_found{$sbj_id} = 1;
    }
    
    ## if this combination doesn't exist yet, create its Seq-pair-alignment
    if (! exists $data{$qry_id}{$sbj_id}) {
        ## skipped attributes here are complength, compstart, compend and method
        $data{$qry_id}{$sbj_id} = $doc->createAndAddSequencePairAlignment( refseq => $qry_id,
                                                                           refxref => ":$qry_id",
                                                                           refstart => 0,
                                                                           refend => $cols[2] - 1,
                                                                           reflength => $cols[2],
                                                                           compseq => $sbj_id,
                                                                           compxref => "$cols[4]:$sbj_id",
                                                                         );

        ## add the total_score (will be the same for each matching segment)
        $doc->createAndAddBsmlAttribute($data{$qry_id}{$sbj_id}, 'total_score', $cols[18]);
    }
    
    ## now add the Seq-pair-run
    ## skipped attributes are runprob
    my $run = $doc->createAndAddSequencePairRun(   alignment_pair => $data{$qry_id}{$sbj_id},
                                                   runscore => $cols[12],
                                                   runlength => abs($cols[7] - $cols[6]) + 1,
                                                   comprunlength => abs($cols[9] - $cols[8]) + 1,
                                                   refpos => min($cols[6], $cols[7]) - 1,
                                                   refcomplement => $cols[17] eq 'Minus' ? 1 : 0,
                                                   comppos => min($cols[8], $cols[9]) - 1,
                                                   compcomplement => 0
                                               );
    
    $doc->createAndAddBsmlAttribute($run, 'percent_identity', $cols[10]);
    $doc->createAndAddBsmlAttribute($run, 'percent_similarity', $cols[11]);
    $doc->createAndAddBsmlAttribute($run, 'chain_number', $cols[13]);
    $doc->createAndAddBsmlAttribute($run, 'segment_number', $cols[14]);
}

## add the analysis element
$doc->createAndAddAnalysis(
                            id => 'aat_aa_analysis',
                            sourcename => $options{'output'},
                          );

## now write the doc
$doc->write($options{'output'});

exit;


sub check_parameters {
    
    ## make sure input file exists
    if (! -e $options{'input'}) { $logger->logdie("input file $options{'input'} does not exist") }

    ## make user an output file was passed
    if (! $options{'output'}) { $logger->logdie("output option required!") }

    return 1;
}

sub min {
    my ($num1, $num2) = @_;
    
    if ($num1 < $num2) {
        return $num1;
    } else {
        return $num2;
    }
}
