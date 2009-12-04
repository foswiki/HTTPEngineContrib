package Foswiki::Engine::HTTP::CGI;
use strict;

use Cwd                         ();
use File::Spec                  ();
use HTTP::Headers               ();
use HTTP::Status                ();
use Foswiki::Engine::HTTP::Util ();

use Error qw(:try);

*sendResponse = \&Foswiki::Engine::HTTP::Util::sendResponse;

$SIG{CHLD} = sub { wait };

sub new {
    my $class = shift;
    return bless {@_}, ref($class) || $class;
}

sub send_response {
    my ( $this, $sock ) = @_;

    my $file = File::Spec->catdir( $this->{scriptdir}, $this->{action} );
    if ( -e $file && !-d _ ) {
        unless ( -x _ ) {
            sendResponse( $sock, 403 );
        }

        my ( $write, $stdin );
        my ( $read,  $stdout );
        my ( $err,   $stderr );
        unless ( pipe( $write, $stdin )
            && pipe( $read, $stdout )
            && pipe( $err,  $stderr ) )
        {
            sendResponse( $sock, 500 );
        }

        my $pid = fork;
        if ( !defined $pid ) {
            sendResponse( $sock, 500 );
        }
        elsif ( $pid > 0 ) {    # Parent process
            foreach ( $stdin, $stdout, $stderr ) {
                close($_);
            }
            my ( $headers, $input_ref );
            try {
                ( $headers, $input_ref ) =
                  Foswiki::Engine::HTTP::Util::readHeader( $read,
                    $this->{opts} );
            };
            my $out_buf = $headers->as_string if $this->{proto} >= 1;

            if ( defined $this->{headers}->content_length ) {
                sendResponse( $sock, 500 )
                  unless $this->{headers}->content_length =~ /^\d+$/
                      && $this->{headers}->content_length > 0;
                try {
                    $this->bridge( $sock, $write, undef, $input_ref,
                        \$out_buf );
                };
            }
            else {
                syswrite( $sock, $out_buf ) if $out_buf;
            }
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
            chdir( ( $this->{scriptdir} =~ /^(.*)$/ )[0] );
            #TODO: add error handling
            %ENV = $this->hdr2env;
            $file =~ /^(.*)$/;
            exec {$1} $1;
        }
        else {
            sendResponse( $sock, 500 );
        }
    }
    else {
        sendResponse( $sock, 404 );
    }
}

sub hdr2env {
    my $this = shift;
    my %cgi  = (
        GATEWAY_INTERFACE => 'CGI/1.1',
        PATH_INFO         => ${ $this->{path_info_ref} } || '',
        QUERY_STRING      => ${ $this->{query_string_ref} } || '',
        REMOTE_ADDR       => $this->{opts}{peeraddr},
        REMOTE_HOST       => '',
        REQUEST_METHOD    => uc( $this->{method} ),
        SCRIPT_NAME       => "$this->{opts}{scripturlpath}/$this->{action}",
        SERVER_PORT       => $this->{server_port},
        SERVER_PROTOCOL   => "HTTP/$this->{proto}",
        SERVER_SOFTWARE   => 'Foswiki/HTTPEngineContrib',
    );
    $cgi{SERVER_NAME} = $this->{headers}->header('Host')
      || $this->{opts}{sockaddr};
    $cgi{CONTENT_TYPE} = $this->{headers}->content_type
      if $this->{headers}->content_type;
    $cgi{CONTENT_LENGTH} = $this->{headers}->content_length
      if $this->{headers}->content_length;
    foreach my $hdr ( $this->{headers}->header_field_names ) {
        next if $hdr =~ /^Content-(?:Type|Length)$/i;
        my $hdrkey = 'HTTP_' . uc($hdr);
        $hdrkey =~ tr/-/_/;
        $cgi{$hdrkey} = $this->{headers}->header($hdr);
    }
    return %cgi;
}

sub bridge {
    my ( $from, $to, $err, $from_buf_ref, $to_buf_ref ) = @_;
}

1;
