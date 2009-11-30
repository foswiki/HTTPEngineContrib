package Foswiki::Engine::HTTP::Native;
use strict;

use Foswiki;
use Foswiki::UI;

my @sorted_actions = ();

$Foswiki::cfg{ScriptUrlPath} =~ s{/+$}{};

@sorted_actions =
  map { { action => $_, path => $Foswiki::cfg{ScriptUrlPaths}{$_} } } sort {
    length( $Foswiki::cfg{ScriptUrlPaths}{$b} ) <=>
      length( $Foswiki::cfg{ScriptUrlPaths}{$a} )
  } keys %{ $Foswiki::cfg{ScriptUrlPaths} }
  if exists $Foswiki::cfg{ScriptUrlPaths};


1;
