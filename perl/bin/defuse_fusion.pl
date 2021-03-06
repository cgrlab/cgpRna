#!/usr/bin/perl
##########LICENCE ##########
#Copyright (c) 2015 Genome Research Ltd.
###
#Author: Cancer Genome Project <cgpit@sanger.ac.uk>
###
#This file is part of cgpRna.
###
#cgpRna is free software: you can redistribute it and/or modify it under
#the terms of the GNU Affero General Public License as published by the
#Free Software Foundation; either version 3 of the License, or (at your
#option) any later version.
###
#This program is distributed in the hope that it will be useful, but
#WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero
#General Public License for more details.
###
#You should have received a copy of the GNU Affero General Public
#License along with this program. If not, see
#<http://www.gnu.org/licenses/>.
###
#1. The usage of a range of years within a copyright statement contained
#within this distribution should be interpreted as being equivalent to a
#list of years including the first and last year specified and all
#consecutive years between them. For example, a copyright statement that
#reads ‘Copyright (c) 2005, 2007- 2009, 2011-2012’ should be interpreted
#as being identical to a statement that reads ‘Copyright (c) 2005, 2007,
#2008, 2009, 2011, 2012’ and a copyright statement that reads ‘Copyright
#(c) 2005-2012’ should be interpreted as being identical to a statement
#that reads ‘Copyright (c) 2005, 2006, 2007, 2008, 2009, 2010, 2011,
#2012’."
##########LICENCE ##########
##########
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings FATAL => 'all';
use autodie qw(:all);
use English qw( -no_match_vars );

use File::Path qw(remove_tree make_path);
use Getopt::Long;
use File::Spec;
use Pod::Usage qw(pod2usage);
use List::Util qw(first);
use Const::Fast qw(const);
use File::Copy;
use Config::IniFiles;
use version;
use Cwd;

use PCAP::Cli;
use Sanger::CGP::Defuse::Implement;

my $ini_file = "$FindBin::Bin/../config/defuse.ini"; # default config.ini file path
const my @REQUIRED_PARAMS => qw(outdir sample);
const my @VALID_PROCESS => qw(prepare merge defuse filter);
const my %INDEX_FACTOR => (	'prepare' => -1,
				'merge' => 1,
				'defuse' => 1,
				'filter' => 1);

{
	my $options = setup();
	
	if(!exists $options->{'process'} || $options->{'process'} eq 'prepare'){
		# Process the input files.
		my $threads = PCAP::Threaded->new($options->{'threads'});
		&PCAP::Threaded::disable_out_err if(exists $options->{'index'});
		$threads->add_function('prepare', \&Sanger::CGP::Defuse::Implement::prepare);
		$threads->run($options->{'max_split'}, 'prepare', $options);
	}
	
	# If multiple BAMs or pairs of fastq files have been input, merge into one pair of fastqs
	if($options->{'max_split'} > 1){
		Sanger::CGP::Defuse::Implement::merge($options) if(!exists $options->{'process'} || $options->{'process'} eq 'merge');
	}
	
	Sanger::CGP::Defuse::Implement::defuse($options) if(!exists $options->{'process'} || $options->{'process'} eq 'defuse');
	
	if(!exists $options->{'process'} || $options->{'process'} eq 'filter'){
		Sanger::CGP::Defuse::Implement::filter_fusions($options);
		cleanup($options);
	}
}

sub cleanup {
	my $options = shift;
	my $tmpdir = $options->{'tmp'};
	Sanger::CGP::Defuse::Implement::compress_sam($options);
	move(File::Spec->catdir($tmpdir, 'logs'), File::Spec->catdir($options->{'outdir'}, 'logs_defuse')) || die $!;
	remove_tree $tmpdir if(-e $tmpdir);
	return 0;
}

sub setup {
	my %opts;
	pod2usage(-msg => "\nERROR: Options must be defined.\n", -verbose => 1, -output => \*STDERR) if(scalar @ARGV == 0);
	$opts{'cmd'} = join " ", $0, @ARGV;
	
	GetOptions( 	'h|help' => \$opts{'h'},
			'm|man' => \$opts{'m'},
			'v|version' => \$opts{'version'},
			'o|outdir=s' => \$opts{'outdir'},
			's|sample=s' => \$opts{'sample'},
			'sp|species=s' => \$opts{'species'},
			'rb|refbuild=s' => \$opts{'referencebuild'},
			'gb|genebuild=i' => \$opts{'genebuild'},
			'r|refdataloc=s' => \$opts{'refdataloc'},
			'n|normals=s' => \$opts{'normalfusionslist'},
			'd|defuseconfig=s' => \$opts{'defuseconfig'},
			't|threads=i' => \$opts{'threads'},
			'p|process=s' => \$opts{'process'},
			'i|index=i' => \$opts{'index'},
			'c|config=s' => \$opts{'config'},
	) or pod2usage(1);

	pod2usage(-verbose => 1) if(defined $opts{'h'});
	pod2usage(-verbose => 2) if(defined $opts{'m'});

	# Read in the config.ini file
	$ini_file = $opts{'config'} if(defined $opts{'config'});
	die "No config file has been specified." if($ini_file eq '');
	my $cfg = new Config::IniFiles( -file => $ini_file ) or die "Could not open config file: $ini_file";
	$opts{'config'} = $ini_file;
	
	# Populate the options hash with values from the config file
	$opts{'refdataloc'} = $cfg->val('defuse-config','referenceloc') unless(defined $opts{'refdataloc'});
	$opts{'referencebuild'} = $cfg->val('defuse-config','referencebuild') unless(defined $opts{'referencebuild'});
	$opts{'genebuild'} = $cfg->val('defuse-config','genebuild') unless(defined $opts{'genebuild'});
	$opts{'normalfusionslist'} = $cfg->val('defuse-config','normalfusionslist') unless(defined $opts{'normalfusionslist'});
	$opts{'species'} = $cfg->val('defuse-config','species') unless(defined $opts{'species'});
	$opts{'defusepath'} = $cfg->val('defuse-config','defusepath');
	$opts{'defuseversion'} = $cfg->val('defuse-config','defuseversion');
	$opts{'defuseconfig'} = $cfg->val('defuse-config','defuseconfig') unless(defined $opts{'defuseconfig'});

	# Print version information for this program (deFuse itself does not have a -v or --version option)
	if($opts{'version'}) {
		print 'CGP defuse.pl version: ',Sanger::CGP::Defuse::Implement->VERSION,"\n";
		print 'deFuse version: ',$opts{'defuseversion'},"\n" if(defined $opts{'defuseversion'});
		exit 0;
	}
		
	for(@REQUIRED_PARAMS) {
		pod2usage(-msg => "\nERROR: $_ is a required argument.\n", -verbose => 1, -output => \*STDERR) unless(defined $opts{$_});
	}
	
	# Check the output directory exists and is writeable, create if not
	PCAP::Cli::out_dir_check('outdir', $opts{'outdir'});
	
	my $tmpdir = File::Spec->catdir($opts{'outdir'}, 'tmpDefuse');
	make_path($tmpdir) unless(-d $tmpdir);
	$opts{'tmp'} = $tmpdir;
	my $progress = File::Spec->catdir($tmpdir, 'progress');
	make_path($progress) unless(-d $progress);
	my $logs = File::Spec->catdir($tmpdir, 'logs');
	make_path($logs) unless(-d $logs);
	my $input = File::Spec->catdir($tmpdir, 'input');
	make_path($input) unless(-d $input);
	
	# Check the input is fastq (paired only) or BAM and that a mixture of these file types hasn't been entered
	$opts{'raw_files'} = \@ARGV;
	Sanger::CGP::Defuse::Implement::check_input(\%opts);

	delete $opts{'process'} unless(defined $opts{'process'});
	delete $opts{'index'} unless(defined $opts{'index'});
	delete $opts{'config'} unless(defined $opts{'config'});

 	# Apply defaults
	$opts{'threads'} = 1 unless(defined $opts{'threads'});
	
	if(exists $opts{'process'}){
		PCAP::Cli::valid_process('process', $opts{'process'}, \@VALID_PROCESS);
		my $max_index = $INDEX_FACTOR{$opts{'process'}};
		
		$max_index = $opts{'max_split'} if($opts{'process'} eq 'prepare');
		
		if(exists $opts{'index'}) {
			if($opts{'process'} eq 'prepare'){
			PCAP::Cli::opt_requires_opts('index', \%opts, ['process']);
			PCAP::Cli::valid_index_by_factor('index', $opts{'index'}, $max_index, 1);
			$opts{'max_split'} = $opts{'index'};
			}
			else{
				die "Index is not a valid for process $opts{'process'}, please re-run without the -i parameter.\n";
			}
		}
	}
	elsif(exists $opts{'index'}) {
	die "ERROR: -index cannot be defined without -process\n";
}

	return \%opts;
}

__END__

=head1 defuse.pl

Cancer Genome Project implementation of the deFuse RNA-Seq algorithm
https://bitbucket.org/dranew/defuse

=head1 SYNOPSIS

defuse_fusion.pl [options] [file(s)...]

  Required parameters:
    -outdir    		-o   	Folder to output result to.
    -sample   		-s   	Sample name

  Optional
    -defuseconfig 	-d  	Name of the defuse config file. It should reside under /refdataloc/species/refbuild/defuse/genebuild/ [defuse-config.txt]
    -normals  	  	-n  	File containing list of gene fusions detected in normal samples. It should reside under /refdataloc/species/refbuild/ [normal-fusions]
    -threads   		-t  	Number of cores to use. [1]
    -config   		-c  	Path to config.ini file. The file contains defaults for the reference data and deFuse software installation details [<cgpRna-install-location>/perl/config/defuse.ini]
    -refbuild 		-rb 	Reference assembly version. Can be UCSC or Ensembl format e.g. GRCh38 or hg38 [GRCh38] 
    -genebuild 		-gb 	Gene build version. This needs to be consistent with the reference build in terms of the version and chromosome name style. Please use the build number only minus any prefixes such as e/ensembl [77]
    -refdataloc  	-r  	Parent directory of the reference data.
    -species  		-sp 	Species [human]

  Targeted processing (further detail under OPTIONS):
    -process   		-p   	Only process this step then exit
    -index    		-i   	Only valid for process prepare - 1..<num_input_files>

  Other:
    -help      		-h   	Brief help message.
    -man       		-m   	Full documentation.
    -version   		-v   	Version

  File list can be full file names or wildcard, e.g.
    defuse_fusion.pl -t 16 -o myout -refbuild GRCh38 -genebuild 77 -s sample input/*.bam

  Run with '-m' for possible input file types.

=head1 OPTIONS

=over 2

=item B<-process>

Available processes for this tool are:

  prepare
  merge
  defuse
  filter

=back

=head2 INPUT FILE TYPES

There are several types of file that the script is able to process.

=over 8

=item f[ast]q

A standard uncompressed fastq file. Requires a pair of inputs with standard suffix of '_1' and '_2'
immediately prior to '.f[ast]q'.

=item f[ast]q.gz

As *.f[ast]q but compressed with gzip.

=item bam

A list of single lane BAM files, RG line is transfered to aligned files.

=back

N.B. Interleaved fastq files are not valid for deFuse.
