package Foswiki::Engine::HTTP::Native;
use strict;

BEGIN {
    eval {
        require Foswiki;
        require Foswiki::UI;
    };
}

$Foswiki::cfg{ScriptUrlPath} =~ s{/+$}{}
  if defined $Foswiki::cfg{ScriptUrlPath};

sub existsAction {
    return
      defined $Foswiki::cfg{SwitchBoard} && $Foswiki::cfg{SwitchBoard}{ $_[0] };
}

sub shorterUrlPaths {
    my @sorted_actions =
      map { { action => $_, path => $Foswiki::cfg{ScriptUrlPaths}{$_} } } sort {
        length( $Foswiki::cfg{ScriptUrlPaths}{$b} ) <=>
          length( $Foswiki::cfg{ScriptUrlPaths}{$a} )
      } keys %{ $Foswiki::cfg{ScriptUrlPaths} }
      if exists $Foswiki::cfg{ScriptUrlPaths};

    return @sorted_actions;
}

sub new {
    my $class = shift;
    my $this = bless {@_}, ref($class) || $class;
    return $this;
}

sub send_response {
    my $this = shift;

    my $engine = $Foswiki::engine;
    $engine->{args}   = { %{$this} };
    $engine->{client} = shift;
    my $req = $engine->prepare();
    if ( UNIVERSAL::isa( $req, 'Foswiki::Request' ) ) {
        my $res = Foswiki::UI::handleRequest($req);
        $engine->finalize( $res, $req );
    }
    delete $engine->{args};
    delete $engine->{client};
}

1;
