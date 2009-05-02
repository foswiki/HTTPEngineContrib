package Foswiki::Engine::HTTP::CGI;
use strict;

use HTTP::Headers ();
use HTTP::Status  ();

sub new {
    my $class = shift;
    return bless {@_}, ref($class) || $class;
}

sub send_response {
    my ( $this, $sock ) = @_;

    if ( -e $this->{file} && !-d _ ) {
        unless ( -x _ ) {
            return 403;
        }

        my ( $write, $stdin );
        my ( $read,  $stdout );
        my ( $err,   $stderr );
        unless ( pipe( $rh, $wh ) ) {
            return 501;
        }
        
        my $pid = fork;
        if ( $pid > 0 ) {    # Parent process
            foreach ($stdin, $stdout, $stderr) {
                close($_);
            }
            while (sysread($read, my ($buffer), 4096)) {
                last unless syswrite($sock, $buffer);
            }
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
            exec($this->{script}, '');
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

1;
