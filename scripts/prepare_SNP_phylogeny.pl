#!/usr/bin/env perl

use strict;
use Getopt::Long;
use File::Basename;
use Cwd;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use JSON;

my $contig;
my @pair_read;
my $single_end_read;
my $project_name;
my $outputDir="SNP_phylogeny";
my $ref_id_map;
my $SNPdbName;
my $genomes;
my $genomesFiles;
my $reference;
my $ref_json_file;
my $bwa_index_id_map;
my $treeMaker="FastTree";
my $NCBI_bwa_genome_index;
my $numCPU = 4;
my $version = "0.2";

my $EDGE_HOME = $ENV{EDGE_HOME};
$EDGE_HOME ||= "$RealBin/../..";

GetOptions(
   'c=s'      => \$contig,
   'p=s{2}'   => \@pair_read,
   's=s'      => \$single_end_read,
   'n=s'      => \$project_name,
   'o=s'      => \$outputDir,
   'map=s'    => \$ref_id_map,
   'db=s'     => \$SNPdbName,
   'ref_json=s'	=> \$ref_json_file,
   'bwa_id_map=s' => \$bwa_index_id_map,
   'bwa_genome_index=s' =>\$NCBI_bwa_genome_index,
   'tree=s'	=>\$treeMaker,
   'genomesList=s'	=> \$genomes,
   'genomesFiles=s' => \$genomesFiles,
   'reference=s'  => \$reference,
   'cpu=i'    => \$numCPU,
   'help|h'   => sub{usage()},
);

$project_name ||= "${SNPdbName}_SNP_phylogeny";
$ref_id_map ||= "$RealBin/../database/SNPdb/reference.txt";
$ref_json_file ||= "$RealBin/../edge_ui/data/Ref_list.json";
$bwa_index_id_map ||= "$RealBin/../database/bwa_index/id_mapping.txt";
$NCBI_bwa_genome_index ||= "$RealBin/../database/bwa_index/NCBI-Bacteria-Virus.fna";

unless($contig || @pair_read || $single_end_read) {print "\nPlease provide contig or reads files\n\n"; &usage(); exit;};

`mkdir -p $outputDir`;

my $contig_abs_path = Cwd::abs_path("$contig");
my $outputDir_abs_path = Cwd::abs_path("$outputDir");
my $random_ref=0;
my $reffile;
my $gff_file;
my $updateSNP=2;
my $data_type;
my $cdsSNPS=0;
my $treeMethod = ($treeMaker =~ /FastTree/i)? 1:2;
my %ref_id;
my $refdir;
my $annotation="$outputDir/annotation.txt";
#Name	Description	URL
#Ecoli_042	Escherichia coli 042, complete genome	http://www.ncbi.nlm.nih.gov/nuccore/387605479

## prepare reference SNPdb
if ($genomes || $genomesFiles)
{
    $updateSNP=1;
	my $list = &readListFromJson($ref_json_file); 
	#my @ref_list = keys %$list;
	$refdir = "$outputDir_abs_path/reffiles";
	`mkdir -p $refdir`;
	if ($genomes){
		if ( ! -e $bwa_index_id_map || ! -s $NCBI_bwa_genome_index){
			print "Cannot Find $bwa_index_id_map \n or \n Cannot find $NCBI_bwa_genome_index\n";
			exit;
		}
		open (my $a_fh, ">$annotation") or die "Cannot write to $annotation\n";
		print $a_fh  "Name\tDescription\tURL\n";
		## extract ref genome from bwa index and fasta file
		if ( -f $genomes) # a list file
		{
			open(my $fh, $genomes) or die "Cannot read $genomes\n";
			while(my $line=<$fh>)
			{
				chomp $line;
				#my @ref_name = grep { /$line/ } @ref_list;
				#&extract_ref_seq($ref_name[0],$list,$refdir,$a_fh);
				&extract_ref_seq($line,$list,$refdir,$a_fh);
			}
			close $fh;
		}
		else
		{
			my @names = split /,/,$genomes;
			foreach my $name (@names)
			{
				#my @ref_name = grep { /$name/ } @ref_list;
				#&extract_ref_seq($ref_name[0],$list,$refdir,$a_fh);
				&extract_ref_seq($name,$list,$refdir,$a_fh);
			}
		}	
		close $a_fh;
	}
	if($genomesFiles){
		map{
			my ($name,$path,$suffix)=fileparse("$_",qr/\.[^.]*/);
			open (my $fh, $_) or die "Cannot read $_\n";
			open (my $ofh, ">$refdir/$name.fna") or die "Cannot write $refdir/$name.fna\n";
			print $ofh ">$name\n";
			while(my $line=<$fh>){
				next if($line =~ />/);
				if($line =~ /\w+/){
					print $ofh $line;
				}
			}
			close $fh;
			close $ofh;
		} split /,/,$genomesFiles;
	}
	if($reference){
		my @tmpl = `ls -d $EDGE_HOME/database/NCBI_genomes/$reference*`;
		chomp @tmpl;
		my @gfiles = `ls -S $tmpl[0]/*gbk`;
		my @gfffiles;
		foreach my $gbk (@gfiles){
			chomp $gbk;
			my $gbk_basename=basename($gbk);
			system("$RealBin/genbank2gff3.pl -e 3 --outdir stdout $gbk > $refdir/$gbk_basename.gff");
			push @gfffiles, "$refdir/$gbk_basename.gff";
		}
		my $cat_cmd="$RealBin/cat_gff.pl -i ". join(" ",@gfffiles) . "> $refdir/$reference.gff";
		system($cat_cmd);
		unlink @gfffiles;
		$reffile = "$reference.fna";
		$gff_file = "$reference.gff";
		$cdsSNPS=1;
		$random_ref=1;
	}
}
else{
	## precompute SNPdb
	## Check species in SNPdb
	$random_ref=1;
	$refdir = "$outputDir_abs_path/files";
	open (my $mapfh,$ref_id_map) or die "Cannot open $ref_id_map\n";
	while(<$mapfh>)
	{
	    chomp;
	    my($id,$ref) = split /\s+/,$_;
	    $ref_id{$id}=$ref;
	}
	close $mapfh;
	$reffile= $ref_id{$SNPdbName}.".fna";
	$gff_file= $ref_id{$SNPdbName}.".gff";
	
	my ($name,$path,$suffix)=fileparse("$ref_id_map",qr/\.[^.]*/);
	$cdsSNPS=1 if ( -e "$path/$SNPdbName/$gff_file");
	my $current_db = join(", ",keys(%ref_id));
	unless($SNPdbName) {print "\nPlease specify a db_Name in the SNPdb\nCurrent available db are $current_db.\n\n"; &usage(); exit;}

	if (!$ref_id{$SNPdbName}) 
	{
    	print "\nThe SNPdbName=$SNPdbName SNPdb is not available.\nCurrent available db are $current_db.\n\n"; 
    	exit;
	}
}

## Prepare contig and reads fastq

my $control_file= "$outputDir_abs_path/SNPphy.ctrl";

if (@pair_read)
{
    my $R1_abs_path = Cwd::abs_path("$pair_read[0]");
    my $R2_abs_path = Cwd::abs_path("$pair_read[1]");
    system("ln -sf $R1_abs_path $outputDir_abs_path/${project_name}_R1.fastq");
    system("ln -sf $R2_abs_path $outputDir_abs_path/${project_name}_R2.fastq");
}
if ($single_end_read)
{
    my $S_abs_path = Cwd::abs_path("$single_end_read");
    system("ln -sf $S_abs_path $outputDir_abs_path/${project_name}_SE.fastq");
}
if ($contig)
{
    system("ln -sf $contig_abs_path $outputDir_abs_path/${project_name}.contig");
} 

$data_type = 1 if ( !(@pair_read || $single_end_read) && $contig && (!$genomes||!$genomesFiles)) ;
$data_type = 2 if ( (@pair_read || $single_end_read) && !$contig && (!$genomes||!$genomesFiles)) ;
$data_type = 3 if ( !(@pair_read || $single_end_read) && $contig && ($genomes||$$genomesFiles)) ;
$data_type = 4 if ((@pair_read || $single_end_read) && !$contig && ($genomes||$genomesFiles)) ;
$data_type = 5 if ((@pair_read || $single_end_read) && $contig && (!$genomes||!$genomesFiles)) ;
$data_type = 6 if ((@pair_read || $single_end_read) && $contig && ($genomes||$genomesFiles)) ;

## Prepare Reference and control file
    system("cp -R $RealBin/../database/SNPdb/${SNPdbName}/* $outputDir_abs_path/.") if (! $genomes);
    
    open (my $fh, ">$control_file") or die "Cannot write $control_file\n";
    print $fh <<"CONTRL";
       refdir = $refdir  # directory where reference files are located
      workdir = $outputDir_abs_path  # directory where contigs/reads files are located and output is stored
    reference = $random_ref  # 0:pick a random reference; 1:use given reference
      reffile = $reffile  # reference species to use
      outfile = snp_alignment  # main alignment file name
      cdsSNPS = $cdsSNPS  # 0:no cds SNPS; 1:cds SNPs
       gbfile = $gff_file # GFF filename of reference
    FirstTime = $updateSNP  # 1:yes; 2:update existing SNP alignment
         data = $data_type  # *See below 0:only complete(F); 1:only contig(C); 2:only reads(R); 
                   # 3:combination F+C; 4:combination F+R; 5:combination C+R; 
                   # 6:combination F+C+R; 7:realignment  *See below 
         tree = $treeMethod  # 0:no tree; 1:use FastTree; 2:use RAxML; 3:use both;
    modelTest = 0  # 0:no; 1:yes; # Only used when building a tree using RAxML
        clean = 1  # 0:no clean; 1:clean
      threads = $numCPU  # Number of threads to use
       cutoff = 0  # Mismatch cutoff - ignore SNPs within cutoff length of each other.
CONTRL


sub readListFromJson {
	my $json = shift;
	my $list = {};
	if( -r $json ){
		open JSON, $json;
		flock(JSON, 1);
  		local $/ = undef;
  		$list = decode_json(<JSON>);
  		close JSON;
	}
	return $list;
}

sub extract_ref_seq {
	my $name=shift;
	my $list=shift;
	my $dir=shift;
	my $annotion_fh=shift;
	my $out_file = "$dir/$name.fna";
	open (my $g_fh, ">$out_file") or die "Cannot write $out_file";
	print $g_fh ">$name\n";
	my $seq;
	my $count=0;
	foreach my $acc (@{$list->{$name}})
	{
		my $get = `grep $acc $bwa_index_id_map`;
		my @ref= split /\s+/,$get;
		my $extract_id = shift @ref;
		my ($gi) = $extract_id =~ /gi\|(\d+)/;
		my $ref_name= join(" ",@ref);
		my @seq = `samtools faidx $NCBI_bwa_genome_index \"$extract_id\"`;
		shift @seq;  # remove first line
		$seq .= join("",@seq);
		print $annotion_fh "$name\t".$ref_name."\thttp://www.ncbi.nlm.nih.gov/nuccore/$gi\n" if ($ref_name !~ /plasmid/);
		$count++;
	}
	$seq =~ s/\s//g;
	print $g_fh $seq."\n";
	close $g_fh;
}

sub usage {
     print <<"END";
     Usage: perl $0 [options] -c contig.fasta -p 'reads1.fastq reads2.fastq' -o out_directory [-db Ecoli | -genomes file]
     Version $version
     Input File:
            -c            Contig fasta file
            
            -p            Paired reads in two fastq files and separate by space
            
            -s            Single end reads

            -o            Output Directory (default: SNP_phylogeny)
     
            -db	          Available choices are Ecoli, Yersinia, Francisella, Brucella, Bacillus.
                 OR 
            -genomesList  A comma separated NCBI RefSeq genome names or list in a file (one name per line)
            -genomesFiles A comma separated genome Files
	    -reference    A reference genome name for reads/contigs mapping to 
  
     Options:
            -map          SNPdb name text file. (default: $RealBin/../database/SNPdb/reference.txt) 
            
            -ref_json     SNP reference genome list json file (default: $RealBin/../edge_ui/data/SNP_ref_list.json)
     
            -bwa_id_map   BWA index id map file (default: $RealBin/../database/bwa_index/id_mapping.txt)
            
            -bwa_genome_index  (default: $RealBin/../database/bwa_index/NCBI-Bacteria-Virus.fna)
            
            -tree         Tree Maker: FastTree or RAxML
            
            -n            Name of the project

            -cpu          number of CPUs (default: 4)
 
            -version      Print verison

END
exit;
}
