package Foswiki::Engine::HTTP::CGI;
use strict;

use File::Spec ();
use HTTP::Headers               ();
use HTTP::Status                ();
use Foswiki::Engine::HTTP::Util ();

*sendResponse = \&Foswiki::Engine::Util::sendResponse;

sub new {
    my $class = shift;
    return bless {@_}, ref($class) || $class;
}

sub send_response {
    my ( $this, $sock ) = @_;

    if (
        -e File::Spec->catpath( $this->{scriptdir}, $this->{action},
            $this->{scriptsuffix} )
        && !-d _
      )
    {
        unless ( -x _ ) {
            sendResponse($sock, 403);
        }

        my ( $write, $stdin );
        my ( $read,  $stdout );
        my ( $err,   $stderr );
        unless ( pipe( $write, $stdin )
            && pipe( $read, $stdout )
            && pipe( $err,  $stderr ) )
        {
            sendResponse( $sock, 501 );
        }

        my $pid = fork;
        if ( !defined $pid ) {
            sendResponse( $sock, 501 );
        }
        elsif ( $pid > 0 ) {    # Parent process
            foreach ( $stdin, $stdout, $stderr ) {
                close($_);
            }
            if (defined $this->{headers}->content_length) {
                sendResponse($sock, 400) unless $this->{headers}->content_length > 0;
                try {
                    bridge( $sock, $write, undef,
                        $this->{headers}{'Content-Length'},
                        $this->{input_ref} );
                };
            }
            my ( $headers, $input_ref );
            try {
                ( $headers, $input_ref ) =
                  Foswiki::Engine::HTTP::Util::readHeader( $sock,
                    $this->{opts} );
            };
            wait;
        }
        elsif ( $pid == 0 ) {    # Child
            untie(*STDIN);
            untie(*STDOUT);
            untie(*STDERR);
            open STDIN,  '<&', $stdin;
            open STDOUT, '>&', $stdout;
            open STDERR, '>&', $stderr;
            foreach ( $write, $read, $err, $stdin, $stdout, $stderr, $sock ) {
                close($_);
            }
            chdir $Foswiki::cfg{HTTPEngineContrib}{BinDir};
            %ENV = $this->hdr2env;
            exec( $this->{script}, '' );
        }
        else {
            return 501;
        }
    }
    else {
        return 404;
    }
}

sub _hdr2env {
    my $this = shift;
}

sub bridge {
    my ($from, $to, $err) = @_;
}

1;
