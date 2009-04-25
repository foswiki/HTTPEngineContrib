#!/usr/bin/perl -wT

use Cwd            ();
use File::Spec     ();
use File::Basename ();

BEGIN {
    $Foswiki::cfg{Engine} = 'Foswiki::Engine::HTTP';
    my $coreDir = Cwd::abs_path(
        File::Spec->catdir( File::Basename::dirname(__FILE__), '..' ) );
    my ($setLibCfg) =
      File::Spec->catdir( $coreDir, 'bin', 'setlib.cfg' ) =~ /^(.*)$/;
    do $setLibCfg;
}

use strict;

use Foswiki;
use Foswiki::UI;

$Foswiki::engine->run();
