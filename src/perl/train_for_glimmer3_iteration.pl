#!/usr/local/bin/perl

eval 'exec /local/packages/perl-5.8.8/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell
use lib (@INC,$ENV{"PERL_MOD_DIR"});
no lib "$ENV{PERL_MOD_DIR}/i686-linux";
no lib ".";


use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev pass_through);
use Ergatis::Logger;
use XML::Twig;
use Config::IniFiles;
use Data::Dumper;

##### GLOBALS ######
my @predictFiles;
my @fsaFiles;
my $confIniFile;
my $outputPWM;
my $outputStartProp;
my $transTable;
my $tmpDir;
my $length;
my $glimmerDir = "/usr/local/devel/ANNOTATION/glimmer/current";
my $elph = "/usr/local/bin/elph";
####################

my %options = ();
my $results = GetOptions (\%options, 
                          'input_predict_list|i=s',
                          'input_fasta_list|f=s',
                          'conf_ini_file|c=s',
                          'output_pwm|o=s',
                          'trans_table|z=s',
                          'tmp_dir|t=s',
                          'glimmer_dir|g=s',
                          'log|l=s',
                          'debug=s',
                          'help|h') || &_pod;

#Setup the logger
my $logfile = $options{'log'} || Ergatis::Logger::get_default_logfilename();
my $logger = new Ergatis::Logger('LOG_FILE'=>$logfile,
				  'LOG_LEVEL'=>$options{'debug'});
$logger = $logger->get_logger();

# Check the options.
&check_parameters(\%options);

my $inputFiles = &createFileNameLookup(\@predictFiles, \@fsaFiles);

&getTrainingCoords($inputFiles);
&createPWM($inputFiles);

### SUB_ROUTINES ###

sub getTrainingCoords {
    my $files = shift;
    
    my $fakeId = 0;
    my $retval = [];

    foreach my $id ( keys %{$files}) {
        
        my $predFile = $files->{$id}->{'predict'};

        my $outFile = "$tmpDir/$id.coords";
        my $results;
      
        print "Reading $predFile\n";
        open(IN, "< $predFile") or 
            $logger->logdie("Unable to open $predFile");

        while(<IN>) {
            my @tmp = split /\s+/;
            next if(@tmp != 5);
            @{$results->{$fakeId}} = ($tmp[1], $tmp[2], $tmp[3], $tmp[4]);
            $fakeId++;
        }
        close(IN);

        my $orfCount = 0;

        print "Printing to $outFile\n";
        open(OUT, "> $outFile") or
            $logger->logdie("Can't open $outFile for writing");
        foreach my $orf ( sort { $a <=> $b } keys %{$results} ) {
            my $tmp = join("\t", @{$results->{$orf}});
            print OUT "$orf\t$tmp\n";
            $orfCount++;
        }
        close(OUT);

        $files->{$id}->{'coordFile'} = $outFile;
        $files->{$id}->{'orfCount'} = $orfCount;

    }

    
}

sub createPWM {
    my $files = shift;
    my $upCmd = "$glimmerDir/scripts/upstream-coords.awk";
    my $opts = " 25 0 ";
    my $extract = " | $glimmerDir/bin/extract ";

    my $outFile = "$tmpDir/all.upstream";
       
    foreach my $id ( keys %{$files} ) {

        if( -e $outFile ) {
            $logger->warn("Removing $outFile");
            system("rm -f $outFile");
        }

        my $runCmd = $upCmd.$opts.$files->{$id}->{'coordFile'}.$extract.$files->{$id}->{'fsa'}." - >> ".$outFile;
        system($runCmd);

        $runCmd = "$glimmerDir/bin/start-codon-distrib -3 ".$files->{$id}->{'fsa'}." ".
            $files->{$id}->{'coordFile'};

        open(USE, " $runCmd |") or
            $logger->logdie("Couldn't run command $runCmd ($!)");

        my $startUse = <USE>;
        close(USE);

        $logger->logdie("$runCmd returned nothing") unless($startUse);
        chomp($startUse);
        $files->{$id}->{'startCodonUsage'} = $startUse;
    }

    my $startCodonUsage = &consolidateStartCodonUsages( $files );

    my $elphOut = $outputPWM;
    my $elphCmd = "$elph $outFile LEN=6 | $glimmerDir/scripts/get-motif-counts.awk > $elphOut";

    system($elphCmd);
    
    print "Ran $elphCmd\n";
}

sub consolidateStartCodonUsages {
    my $files = shift;
    my @totals;

    my $check;

    foreach my $id ( keys %{$files} ) {
        
        #Multiply total number of orfs by percentages to get total counts
        my @indCodonUsage = split(/,/, $files->{$id}->{'startCodonUsage'});
        my $orfCount = $files->{$id}->{'orfCount'};

        my @tmpTotal = map($_*$orfCount,@indCodonUsage);

        for(my $i = 0; $i < 3; $i++) {
            $totals[$i]+=int($tmpTotal[$i]+.5);
        }

        $totals[3]+=$orfCount;
    }

    #I multiply by 1000 because of rounding.
    #And then I divide again.
    for(my $i = 0; $i < 3; $i++) {
        $totals[$i] = ($totals[$i]/$totals[3]) * 1000; 
        $totals[$i] = int($totals[$i]+0.5)/1000;
    }

    my $str = join(',', @totals[0..2]);

    #Store the start codon usage result somewhere
    &storeStartCodonUsageResult($str);

}

sub storeStartCodonUsageResult {
    my $str = shift;

    my $cfg = new Config::IniFiles( -file => "$confIniFile" );

    my $val;
    $val = $cfg->setval('input glimmer3', '$;START_CODON_USAGE$;', $str);               #Ergatis v1
    $val = $cfg->setval('parameters', '$;START_CODON_USAGE$;', $srt) unless($val);      #Ergatis v2
    $logger->logdie("Cannot set value of \$;START_CODON_USAGE\$; in $confIniFile to $str") unless($val);
    $cfg->WriteConfig($confIniFile);
}

sub createFileNameLookup {
    my ($predList, $fsaList) = @_;
    my $retval;

    foreach my $pred ( @{$predList} ) { 
       
        my $base = $1 if($pred =~ m|/(([^/\.]+\.){3})|);
        $base =~ s/\.$//;
        $logger->logdie("Could not parse out basename from $pred") unless($base);
        my $found = 0;

        print "\nLooking for fsa for $base\n";

        foreach my $fsa ( @{$fsaList} ) {
            
            print "fsa: $fsa\n";

            if($fsa =~ /$base\./) {
                $retval->{$base}->{'predict'} = $pred;
                $retval->{$base}->{'fsa'} = $fsa;
                $found++;
            }

        }

        unless($found) {
            $logger->logdie("Could not find matching fsa file for $pred");
        }

    }

    return $retval;
}

sub check_parameters {
    my $opts = shift;

    # input_bsml_list is required
    unless($opts->{'input_predict_list'}) {
        $logger->logdie("Option input_predict_list is required");
    }
    open(IN, "< $opts->{'input_predict_list'}") or
        $logger->logdie("Can't open file $opts->{'input_predict_list'} ($!)");
    @predictFiles = grep /predict/, <IN>;
    chomp(@predictFiles);
    close(IN);

    # input_fasta_list is required
    unless($opts->{'input_fasta_list'}) {
        $logger->logdie("Option input_fasta_list is required");
    }
    open(FSA, "<$opts->{'input_fasta_list'}")
        or $logger->logdie("Unable to open $opts->{'input_fasta_list'} ($!)");
    @fsaFiles = <FSA>;
    close(FSA);
    chomp(@fsaFiles);

    # option confIniFile is required
    unless($opts->{'conf_ini_file'}) {
        $logger->logdie("Option conf_ini_file is required");
    } else {
        $confIniFile = $opts->{'conf_ini_file'};
    }

    # output_pwn is required
    unless($opts->{'output_pwm'}) {
        $logger->logdie("Option output_pwn is required ($opts->{'output_pwm'})");
    } else {
        $outputPWM = $opts->{'output_pwm'};
    }

    # tmp_dir is required
    unless($opts->{'tmp_dir'}) {
        $logger->logdie("Option tmp_dir is required");
    } else {
        $tmpDir = $opts->{'tmp_dir'};
        $tmpDir =~ s/\/$//;
    }

    #Optional trans_table
    if($opts->{'trans_table'}) {
        $transTable = $opts->{'trans_table'};
    }

    #Optional glimmer_dir
    if($opts->{'glimmer_dir'}) {
        $glimmerDir = $opts->{'glimmer_dir'};
    }

}