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

sub existsAction {
}

sub shorterUrlPaths {
}

sub handleFoswikiAction {
    my $this = shift;
    my %args = @_;      # method, uri_ref, proto, action, headers,
                        # path_info_ref, query_string_ref

    my $engine = $this->{server}{engine_obj};
    $engine->{args}              = \%args;
    $engine->{args}{server_port} = $this->{server}{port};
    $engine->{args}{http}        = $this;
    $engine->{client}            = $this->{server}{client};
    my $req = $engine->prepare();
    if ( UNIVERSAL::isa( $req, 'Foswiki::Request' ) ) {
        my $res = Foswiki::UI::handleRequest($req);
        $engine->finalize( $res, $req );
    }
    delete $engine->{args};
    delete $engine->{client};
}

1;
