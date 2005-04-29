#!/usr/local/bin/perl

=head1  NAME 

tRNAscan-SE2bsml.pl - convert tRNAcan-SE output to BSML

=head1 SYNOPSIS

USAGE: tRNAscan-SE2bsml.pl --input=/path/to/tRNAscanfile --output=/path/to/output.bsml

=head1 OPTIONS

B<--input,-i> 
    Input file file from a tRNAscan-SE search.

B<--debug,-d> 
    Debug level.  Use a large number to turn on verbose debugging. 

B<--log,-l> 
    Log file

B<--output,-o> 
    Output BSML file (will be created, must not exist)

B<--help,-h> 
    This help message

=head1   DESCRIPTION

This script is used to convert the output from a tRNAscan-SE search into BSML.

=head1 INPUT

tRNAscan-SE can be run using multiple input sequences simultaneously, and this
script supports parsing single or multiple input result sets.  Usual tRNAscan-SE
output looks like:

    Sequence                tRNA            Bounds          tRNA    Anti    Intron Bounds   Cove
    Name            tRNA #  Begin           End             Type    Codon   Begin   End     Score
    --------        ------  ----            ------          ----    -----   -----   ----    ------
    51595           1       101064          101137          Asn     GTT     0       0       82.29
    51595           2       705796          705868          Ala     AGC     0       0       68.12
    ...
    51595           13      3488675         3488743         Pseudo  GTA     0       0       22.49
    51595           14      3493468         3493555         Ser     GCT     3493506 3493513 40.19

You can run elimate the headers in the original tRNAscan-SE output file by running 
tRNAscan-SE using the -b option.  If they are present, they should be ignored by 
this script.

You define the input file using the --input option.  This file does not need any
special file extension.

=head1 OUTPUT

After parsing the input file, a file specified by the --output option is created.  This script
will fail if it already exists.  The file is created, and temporary IDs are created for
each result element.  They are only unique to the document, and will need to be replaced
before any database insertion.

Base positions from the input file are renumbered so that positions start at zero.  The
current output elements from tRNAscan-SE that are not represented in the BSML file are:

    tRNA type
    Anti Codon
    Cove Score

These need to be included later.

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

## we want to creating ids unique to this document, which will be replaced later.  they must
##  contain the prefix that will be used to look up a real id, such as ath1.gen.15
my $next_id = 1;

## we want a new doc
my $doc = new BSML::BsmlBuilder();

## open the input file for parsing
open (my $ifh, $options{'input'}) || $logger->logdie("can't open input file for reading");

my %data;
while (<$ifh>) {
    my @cols = split;
    
    #check whitespace, no warn
    next if ( /^\s*$/ );
    
    ## make sure we don't parse the tRNAscan-SE output header lines
    next if ( /^sequence.*bounds.*cove/i ||
              /^name.*end.*score/i ||
              /\-\-.*\-\-/);

    ## there should be 9 elements in cols, unless we have an unrecognized format.
    unless (scalar @cols == 9) {
        $logger->error("the following tRNAscan-SE line was not recognized and could not be parsed:\n$_\n") if ($logger->is_error);
        next;
    }
    
    ## add this data row to this sequence
    push( @{$data{shift @cols}}, \@cols );
}

## loop through each of the matches that we found
for my $seqid (keys %data) {
    my $seq = $doc->createAndAddSequence($seqid);
       $seq->addBsmlLink('analysis', '#tRNAscan-SE_analysis');
    my $ft  = $doc->createAndAddFeatureTable($seq);
    my $fg;
    
    ## loop through each array reference of this key
    my $gene;
    my $trna;
    my $exon;
    my @elements;
    foreach my $arr ( @{$data{$seqid}} ) {
        ## 1 is subtracted from each position to give interbase numbering
        $$arr[1]--;     ## tRNA begin
        $$arr[2]--;     ## Bounds End
        
        ## first we need to add the gene, analysis link and interval loc
        $gene = $doc->createAndAddFeature($ft, &fake_id('gen'), '', 'gene');
        $gene->addBsmlLink('analysis', '#tRNAscan-SE_analysis');
        &add_interval_loc( $gene, $$arr[1], $$arr[2] );
        
        ## now add a feature group for each of the elements we add, using the gene id for the group-set
        $fg = $doc->createAndAddFeatureGroup( $seq, '', $gene->returnattr('id') );
        
        ## add the gene to the group
        $fg->addBsmlFeatureGroupMember( $gene->returnattr('id'), $gene->returnattr('class') );
        
        ## add the tRNA, analysis link and interval loc
        $trna = $doc->createAndAddFeature($ft, &fake_id('trn'), '', 'tRNA');
        $trna->addBsmlLink('analysis', '#tRNAscan-SE_analysis');
        &add_interval_loc( $trna, $$arr[1], $$arr[2] );
        $fg->addBsmlFeatureGroupMember( $trna->returnattr('id'), $trna->returnattr('class') );
        
        ## an exon needs to be added.  the following will eval as true if tRNAscan-SE reported an
        ##  intron in the sequence, else the entire range is added as an exon.  this seems to limit
        ##  tRNAscan-SE to only report tRNAs with 0 or 1 intron.
        if ($$arr[5] && $$arr[6]) {
            ## 1 is subtracted from each position to give interbase numbering
            $$arr[5]--;     ## Intron Begin
            $$arr[6]--;     ## Bounds End
            
            ## exon1
            $exon = $doc->createAndAddFeature($ft, &fake_id('exo'), '', 'exon');
            $exon->addBsmlLink('analysis', '#tRNAscan-SE_analysis');
            &add_interval_loc( $exon, $$arr[1], $$arr[5] );
            $fg->addBsmlFeatureGroupMember( $exon->returnattr('id'), $exon->returnattr('class') );

            ## exon2
            $exon = $doc->createAndAddFeature($ft, &fake_id('exo'), '', 'exon');
            $exon->addBsmlLink('analysis', '#tRNAscan-SE_analysis');
            &add_interval_loc( $exon, $$arr[6], $$arr[2] );
            $fg->addBsmlFeatureGroupMember( $exon->returnattr('id'), $exon->returnattr('class') );                
            
        } else {
            ## just add the whole thing as an exon
            $exon = $doc->createAndAddFeature($ft, &fake_id('exo'), '', 'exon');
            $exon->addBsmlLink('analysis', '#tRNAscan-SE_analysis');
            &add_interval_loc( $exon, $$arr[1], $$arr[2] );
            $fg->addBsmlFeatureGroupMember( $exon->returnattr('id'), $exon->returnattr('class') );
        }
    }
}

## add the analysis element
$doc->createAndAddAnalysis(
                            id => 'tRNAscan-SE_analysis',
                            sourcename => $options{'output'},
                          );

## now write the doc
$doc->write($options{'output'});

exit;

sub add_interval_loc {
    my ($feat, $n, $m) = @_;
    
    ## was it found on the forward or reverse strand?
    if ($n <= $m) {
        $feat->addBsmlIntervalLoc($n, $m, 0);
    } else {
        $feat->addBsmlIntervalLoc($m, $n, 1);
    }
}

sub check_parameters {
    
    ## make sure input file exists
    if (! -e $options{'input'}) { $logger->logdie("input file $options{'input'} does not exist") }
    
    ## make sure output file doesn't exist yet
    if (-e $options{'output'}) { $logger->logdie("can't create $options{'output'} because it already exists") }
    
    return 1;
}

sub fake_id {
    my $so_type = shift;

    ## this will be used by the id replacement software to find ids to replace.
    my $temp_prefix = 'ir';
    
    return "$temp_prefix.$so_type." . $next_id++;
}
