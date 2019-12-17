#! /usr/bin/perl -w
#-------------------------------------------------------------------------
#
# Gen_fmgrtab.pl
#    Perl script that generates fmgroids.h, fmgrprotos.h, and fmgrtab.c
#    from pg_proc.dat
#
# Portions Copyright (c) 1996-2019, PostgreSQL Global Development Group
# Portions Copyright (c) 1994, Regents of the University of California
#
#
# IDENTIFICATION
#    src/backend/utils/Gen_fmgrtab.pl
#
#-------------------------------------------------------------------------

use Catalog;

use strict;
use warnings;
use Getopt::Long;

my $output_path = '';
my $include_path;

GetOptions(
	'output:s'       => \$output_path,
	'include-path:s' => \$include_path) || usage();

# Make sure output_path ends in a slash.
if ($output_path ne '' && substr($output_path, -1) ne '/')
{
	$output_path .= '/';
}

# Sanity check arguments.
die "No input files.\n"                   unless @ARGV;
die "--include-path must be specified.\n" unless $include_path;

# Read all the input files into internal data structures.
# Note: We pass data file names as arguments and then look for matching
# headers to parse the schema from. This is backwards from genbki.pl,
# but the Makefile dependencies look more sensible this way.
# We currently only need pg_proc, but retain the possibility of reading
# more than one data file.
my %catalogs;
my %catalog_data;
foreach my $datfile (@ARGV)
{
	$datfile =~ /(.+)\.dat$/
	  or die "Input files need to be data (.dat) files.\n";

	my $header = "$1.h";
	die "There in no header file corresponding to $datfile"
	  if !-e $header;

	my $catalog = Catalog::ParseHeader($header);
	my $catname = $catalog->{catname};
	my $schema  = $catalog->{columns};

	$catalogs{$catname} = $catalog;
	$catalog_data{$catname} = Catalog::ParseData($datfile, $schema, 0);
}

# Collect certain fields from pg_proc.dat.
my @fmgr = ();

foreach my $row (@{ $catalog_data{pg_proc} })
{
	my %bki_values = %$row;

	# Select out just the rows for internal-language procedures.
	next if $bki_values{prolang} ne 'internal';

	push @fmgr,
	  {
		oid    => $bki_values{oid},
		strict => $bki_values{proisstrict},
		retset => $bki_values{proretset},
		nargs  => $bki_values{pronargs},
		prosrc => $bki_values{prosrc},
		prokind => $bki_values{prokind},
		proname => $bki_values{proname},
		proargtypes => $bki_values{proargtypes},
	  };
}

# Emit headers for both files
my $tmpext     = ".tmp$$";
my $oidsfile   = $output_path . 'fmgroids.h';
my $protosfile = $output_path . 'fmgrprotos.h';
my $tabfile    = $output_path . 'fmgrtab.c';

open my $ofh, '>', $oidsfile . $tmpext
  or die "Could not open $oidsfile$tmpext: $!";
open my $pfh, '>', $protosfile . $tmpext
  or die "Could not open $protosfile$tmpext: $!";
open my $tfh, '>', $tabfile . $tmpext
  or die "Could not open $tabfile$tmpext: $!";

print $ofh <<OFH;
/*-------------------------------------------------------------------------
 *
 * fmgroids.h
 *    Macros that define the OIDs of built-in functions.
 *
 * These macros can be used to avoid a catalog lookup when a specific
 * fmgr-callable function needs to be referenced.
 *
 * Portions Copyright (c) 1996-2019, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * NOTES
 *	******************************
 *	*** DO NOT EDIT THIS FILE! ***
 *	******************************
 *
 *	It has been GENERATED by src/backend/utils/Gen_fmgrtab.pl
 *
 *-------------------------------------------------------------------------
 */
#ifndef FMGROIDS_H
#define FMGROIDS_H

/*
 *	Constant macros for the OIDs of entries in pg_proc.
 *
 *	NOTE: macros are named after the prosrc value, ie the actual C name
 *	of the implementing function, not the proname which may be overloaded.
 *	For example, we want to be able to assign different macro names to both
 *	char_text() and name_text() even though these both appear with proname
 *	'text'.  If the same C function appears in more than one pg_proc entry,
 *	its equivalent macro will be defined with the lowest OID among those
 *	entries.
 */
OFH

print $pfh <<PFH;
/*-------------------------------------------------------------------------
 *
 * fmgrprotos.h
 *    Prototypes for built-in functions.
 *
 * Portions Copyright (c) 1996-2019, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * NOTES
 *	******************************
 *	*** DO NOT EDIT THIS FILE! ***
 *	******************************
 *
 *	It has been GENERATED by src/backend/utils/Gen_fmgrtab.pl
 *
 *-------------------------------------------------------------------------
 */

#ifndef FMGRPROTOS_H
#define FMGRPROTOS_H

#include "fmgr.h"

PFH

print $tfh <<TFH;
/*-------------------------------------------------------------------------
 *
 * fmgrtab.c
 *    The function manager's table of internal functions.
 *
 * Portions Copyright (c) 1996-2019, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * NOTES
 *
 *	******************************
 *	*** DO NOT EDIT THIS FILE! ***
 *	******************************
 *
 *	It has been GENERATED by src/backend/utils/Gen_fmgrtab.pl
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "access/transam.h"
#include "utils/fmgrtab.h"
#include "utils/fmgrprotos.h"

TFH

# Emit #define's and extern's -- only one per prosrc value
my %seenit;
foreach my $s (sort { $a->{oid} <=> $b->{oid} } @fmgr)
{
	if ($s->{prokind} eq "a")
	{
		$s->{proargtypes} =~ s/ /_/;
		print $ofh "#define F_AGG_" . uc $s->{proname} . "_" . uc $s->{proargtypes} . " $s->{oid}\n";
	}

	next if $seenit{ $s->{prosrc} };
	$seenit{ $s->{prosrc} } = 1;
	print $ofh "#define F_" . uc $s->{prosrc} . " $s->{oid}\n";
	print $pfh "extern Datum $s->{prosrc}(PG_FUNCTION_ARGS);\n";
}

# Create the fmgr_builtins table, collect data for fmgr_builtin_oid_index
print $tfh "\nconst FmgrBuiltin fmgr_builtins[] = {\n";
my %bmap;
$bmap{'t'} = 'true';
$bmap{'f'} = 'false';
my @fmgr_builtin_oid_index;
my $last_builtin_oid = 0;
my $fmgr_count       = 0;
foreach my $s (sort { $a->{oid} <=> $b->{oid} } @fmgr)
{
	print $tfh
	  "  { $s->{oid}, $s->{nargs}, $bmap{$s->{strict}}, $bmap{$s->{retset}}, \"$s->{prosrc}\", $s->{prosrc} }";

	$fmgr_builtin_oid_index[ $s->{oid} ] = $fmgr_count++;
	$last_builtin_oid = $s->{oid};

	if ($fmgr_count <= $#fmgr)
	{
		print $tfh ",\n";
	}
	else
	{
		print $tfh "\n";
	}
}
print $tfh "};\n";

printf $tfh qq|
const int fmgr_nbuiltins = (sizeof(fmgr_builtins) / sizeof(FmgrBuiltin));

const Oid fmgr_last_builtin_oid = %u;
|, $last_builtin_oid;


# Create fmgr_builtin_oid_index table.
printf $tfh qq|
const uint16 fmgr_builtin_oid_index[%u] = {
|, $last_builtin_oid + 1;

for (my $i = 0; $i <= $last_builtin_oid; $i++)
{
	my $oid = $fmgr_builtin_oid_index[$i];

	# fmgr_builtin_oid_index is sparse, map nonexistent functions to
	# InvalidOidBuiltinMapping
	if (not defined $oid)
	{
		$oid = 'InvalidOidBuiltinMapping';
	}

	if ($i == $last_builtin_oid)
	{
		print $tfh "  $oid\n";
	}
	else
	{
		print $tfh "  $oid,\n";
	}
}
print $tfh "};\n";


# And add the file footers.
print $ofh "\n#endif\t\t\t\t\t\t\t/* FMGROIDS_H */\n";
print $pfh "\n#endif\t\t\t\t\t\t\t/* FMGRPROTOS_H */\n";

close($ofh);
close($pfh);
close($tfh);

# Finally, rename the completed files into place.
Catalog::RenameTempFile($oidsfile,   $tmpext);
Catalog::RenameTempFile($protosfile, $tmpext);
Catalog::RenameTempFile($tabfile,    $tmpext);

sub usage
{
	die <<EOM;
Usage: perl -I [directory of Catalog.pm] Gen_fmgrtab.pl [--include-path/-i <path>] [path to pg_proc.dat]

Options:
    --output         Output directory (default '.')
    --include-path   Include path in source tree

Gen_fmgrtab.pl generates fmgroids.h, fmgrprotos.h, and fmgrtab.c from
pg_proc.dat

Report bugs to <pgsql-bugs\@lists.postgresql.org>.
EOM
}

exit 0;
