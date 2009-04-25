package Foswiki::Engine::HTTP::Protocol;

use Net::Server::MultiType ();
@ISA = qw(Net::Server::MultiType);

use strict;
use HTTP::Message              ();
use HTTP::Body                 ();
use HTTP::Status               ();
use IO::Select                 ();
use File::Spec                 ();
use Foswiki::Engine::HTTP::CGI ();
use LWP::MediaTypes qw(guess_media_type);

use Assert;
use Error qw(:try);

use Time::HiRes qw(time);
use Errno qw(EINTR EWOULDBLOCK EAGAIN);

BEGIN {
    no warnings 'redefine';
    my $param_ref = \&HTTP::Body::param;
    *HTTP::Body::param = sub {
        my ( $this, $p, $v ) = @_;
        if ( defined $p && defined $v ) {
            push @{ $this->{plist} }, $p unless exists $this->{param}{$p};
        }
        $param_ref->(@_);
    };
    my $upload_ref = \&HTTP::Body::upload;
    *HTTP::Body::upload = sub {
        my ( $this, $p, $v ) = @_;
        $this->param( $p, $v->{filename} ) if defined $p && defined $v;
        $upload_ref->(@_);
    };
    *HTTP::Body::compat_param = sub {
        my $this = shift;
        $this->{plist} ||= [];
        return @{ $this->{plist} } unless @_ > 0;
        my $name = shift;
        return $this->{param}{$name};
    };
    LWP::MediaTypes::read_media_types( $Foswiki::cfg{MimeTypesFileName} );
}

sub options {
    my $this = shift;
    my $prop = $this->{'server'};
    my $ref  = shift;

    ### setup options in the parent classes
    $this->SUPER::options($ref);

    ### add a single value option
    $prop->{foswiki_engine_obj} ||= undef;
    $ref->{foswiki_engine_obj} = $prop->{foswiki_engine_obj};

    foreach (
        qw(foswiki_read_timeout foswiki_limit_request_line
        foswiki_limit_headers foswiki_read_body_timeout)
      )
    {
        $prop->{$_} ||= undef;
        $ref->{$_} = \$prop->{$_};
    }
}

sub default_values {
    my $this = shift;
    my $opts = $this->SUPER::default_values(@_);
    $opts->{foswiki_read_timeout}       = 30;
    $opts->{foswiki_read_body_timeout}  = 300;
    $opts->{foswiki_limit_request_line} = 8192;
    $opts->{foswiki_limit_headers}      = 8192;
    return $opts;
}

sub post_configure_hook {
    ASSERT(
        Universal::isa(
            $_[0]->{server}{foswiki_engine_obj},
            'Foswiki::Engine::HTTP'
        )
    ) if DEBUG;
}

sub process_request {
    my $this = shift;

    my ( $method, $uri, $proto, $headers );

    $this->{foswiki}{timeleft} = $this->{server}{foswiki_read_timeout};
    try {
        my $result =
          $this->getRequestData( $this->{server}{foswiki_limit_request_line},
            \&_getLineBreak );
        ( $method, $uri, $proto ) =
          $$result =~ /^\s*(?:(\w+)\s+(\S+)(?:\s+(\S+))?)?/;
    }
    catch Error::Simple with {
        my $e = shift;
        if ( $e->text eq 'timeout' ) {
            $this->log( 2, 'client <IP> timed out' );
        }
        elsif ( $e->text eq 'request line too long' ) {
            $this->log( 4, 'client <IP> sent a request line too long' );
        }
        $this->returnError( $e->text );
        return;    # Abort the connection
    };

    unless ( defined $method && $method =~ /(?:POST|GET|HEAD)/i ) {
        $this->returnError( 501, 'Not Implemented' );
        return;
    }
    unless ( !defined($proto) || $proto =~ m!HTTP/(?:1\.[01]|0\.9)!i ) {
        $this->returnError( 505, 'HTTP Version Not Supported' );
        return;
    }

    try {
        my $result =
          $this->getRequestData( $this->{server}{foswiki_limit_headers},
            \&_getDoubleLineBreak )
          if $proto && $proto =~ m!HTTP/1\.[01]!i;
        $headers = HTTP::Message->parse($$result)->headers;
    }
    catch Error::Simple with {
        my $e = shift;
        if ( $e->text eq 'timeout' ) {
            $this->log( 4, 'client <IP> timed out' );
        }
        elsif ( $e->text eq 'request headers too large' ) {
            $this->log( 4, 'client <IP> sent headers too large' );
        }
        $this->returnError( $e->text );
        return;    # Abort the connection
    }

    # Check what resource was requested:
    #   - Static file from pub
    #   - Foswiki action or CGI script (without Shorter URLs)
    #   - Foswiki action as a short URL
    # Give up if none of these.
    my $handled = 0;

    if ( index( $uri, $Foswiki::cfg{PubUrlPath} ) == 0 ) {
        $this->handleStaticResponse(
            method  => $method,
            uri_ref => \$uri,
            proto   => $proto,
            headers => $headers,
        );
        $handled = 1;
    }
    elsif ( index( $uri, $Foswiki::cfg{ScriptUrlPath} ) == 0 )
    {    # Foswiki action or CGI script
        my $path = $Foswiki::cfg{ScriptUrlPath};
        $path =~ s{/+$}{};

        my ( $script, $path_info, $query_string ) =
          $uri     =~ m#^\Q$path\E/+([^/\?]+)([^\?]*)(?:\?(.*))?#;
        $path_info =~ s/%(..)/chr(hex($1))/ge;

        unless ( defined $script ) {
            $this->returnError( 403, 'Forbidden' );
            return;    # Abort the connection
        }

        if ( defined $Foswiki::cfg{SwitchBoard}{$script} ) {
            $this->handleFoswikiAction(
                method           => $method,
                uri_ref          => \$uri,
                proto            => $proto,
                headers          => $headers,
                action           => $script,
                path_info_ref    => \$path_info,
                query_string_ref => \$query_string,
            );
            $handled = 1;
        }
        else {
            $this->handleCgiScript(
                method           => $method,
                uri_ref          => \$uri,
                proto            => $proto,
                headers          => $headers,
                script           => $script,
                path_info_ref    => \$path_info,
                query_string_ref => \$query_string,
            );
            $handled = 1;
        }
    }
    elsif ( exists $Foswiki::cfg{ScriptUrlPaths} )
    {    # Try shorter URLs before giving up
        while ( my ( $action, $path ) =
            each %{ $Foswiki::cfg{ScriptUrlPaths} } )
        {
            $path =~ s{/+$}{};
            next unless $uri =~ m#^\Q$path\E(/[^\?]*)(?:\?(.*))?#;
            my ( $path_info, $query_string ) = ( $1, $2 );
            $path_info =~ s/%(..)/chr(hex($1))/ge;
            $this->handleFoswikiAction(
                method           => $method,
                uri_ref          => \$uri,
                proto            => $proto,
                headers          => $headers,
                action           => $action,
                path_info_ref    => \$path_info,
                query_string_ref => \$query_string,
            );
            $handled = 1;
            keys %{ $Foswiki::cfg{ScriptUrlPaths} };    # reset iterator
            last;
        }
    }
    $this->returnError( 404, 'Not Found' ) unless $handled;
}

sub getRequestData {
    my ( $this, $limit, $sub ) = @_;
    my $timeleft = $this->{foswiki}{timeleft};
    my $sel      = IO::Select->new( $this->{server}{client} );
    my $now      = time;
    my $eof      = 0;

    $this->{foswiki}{buffer} ||= '';
    my ( $pos, $p_len ) = $sub->( \$this->{foswiki}{buffer} );
    my $result_str = '';
    if ( $pos >= 0 && $pos + $p_len <= $limit ) {
        $result_str = substr( $this->{foswiki}{buffer}, 0, $pos + $p_len, '' );
        $eof = 1;
    }
    elsif ( $pos >= 0 ) {
        throw Error::Simple('ESIZE');
    }
    else {
        $result_str = substr( $this->{foswiki}{buffer}, 0, $limit, '' );
    }
    my $bytes_read = length($result_str);

    while ( !$eof && $bytes_read < $limit && $timeleft > 0 ) {
        my @ready = $sel->can_read($timeleft);
        $timeleft -= time - $now;
        $now = time;
        if ( @ready == 0 ) {
            next if $! == EINTR;
            throw Error::Simple("EBADF: $!");
        }
        my $rv = sysread( $this->{server}{client}, my ($buffer), $limit );
        unless ( defined $rv ) {
            next if $! == EINTR || $! == EAGAIN || $! == EWOULDBLOCK;
            throw Error::Simple("EBADF: $!");
        }
        ( $pos, $p_len ) = $sub->( \$buffer );
        if ( $pos >= 0 ) {
            throw Error::Simple('ESIZE')
              if ( $bytes_read + $pos + $p_len > $limit );
            $result_str .= substr( $buffer, 0, $pos + $p_len, '' );
            $this->{foswiki}{buffer} = $buffer;
            $eof = 1;
        }
        else {
            $result_str .= $buffer;
        }
        $bytes_read += $rv;
    }
    if ($eof) {
        $this->{foswiki}{timeleft} = $timeleft;
        return \$result_str;
    }
    elsif ( $timeleft <= 0 ) {
        throw Error::Simple('ETIMEOUT');
    }
    elsif ( $bytes_read > $limit ) {
        throw Error::Simple('ESIZE');
    }

    # Should never get here
    return ();
}

sub _getLineBreak {
    my $buf_ref = shift;
    if ( $$buf_ref =~ /(\x0D?\x0A|\x0D(?!\x0A))/ ) {
        return ( $-[0], length($1) );
    }
    return ( -1, 0 );
}

sub _getDoubleLineBreak {
    my $buf_ref = shift;
    if ( $$buf_ref =~ /((?:\x0D?\x0A){2}|(?:\x0D\x0A?\x0D(?!\x0A)))/ ) {
        return ( $-[0], length($1) );
    }
    return ( -1, 0 );
}

sub readBody {
    my ( $this, $headers ) = @_;

    my $body = HTTP::Body->new( $headers->header('Content-Type'),
        $headers->content_length );
    $body->add( $this->{foswiki}{buffer} );
    my $bytes_read = length( $this->{foswiki}{buffer} );
    delete $this->{foswiki}{buffer};

    my $timeleft =
      $this->{server}{foswiki_read_body_timeout} + $this->{foswiki}{timeleft};
    my $sel = IO::Select->new( $this->{server}{client} );
    my $now = time;

    while ( $bytes_read < $headers->content_length && $timeleft >= 0 ) {
        my @ready = $sel->can_read($timeleft);
        $timeleft -= time - $now;
        $now = time;
        if ( @ready == 0 ) {
            next if $! == EINTR;
            throw Error::Simple("EBADF: $!");
        }
        my $rv = sysread( $this->{server}{client}, my ($buffer), 4096 );
        unless ( defined $rv ) {
            next if $! == EINTR || $! == EAGAIN || $! == EWOULDBLOCK;
            throw Error::Simple("EBADF: $!");
        }
        $body->add($buffer);
        $bytes_read += $rv;
    }

    throw Error::Simple("EBADREQ")
      unless $bytes_read == $headers->content_length;

    return $body;
}

sub returnError {
    local $, = ' ';
    print STDERR @_, "\n";
}

sub handleStaticResponse {
    my $this = shift;
    my %args = @_;      # method, uri_ref, proto, headers
    substr( ${ $args{uri_ref} }, 0, length( $Foswiki::cfg{PubUrlPath} ), '' );
    ${ $args{uri_ref} } =~ s/\?.*//;
    my @path = File::Spec->no_upwards( split m!/+!, ${ $args{uri_ref} } );
    my $file = File::Spec->catfile( $Foswiki::cfg{PubDir}, @path );
    my $CRLF = "\x0D\x0A";
    if ( -e $file && -r _ && !-d _ ) {
        my ( $size, $mtime ) = ( stat(_) )[ 7, 9 ];
        my $type     = guess_media_type($file);
        my $response = 'HTTP/1.1 200 OK' . $CRLF;
        $response .= 'Content-Type: ' . $type . $CRLF;
        $response .= 'Content-Length: ' . $size . $CRLF . $CRLF;
        syswrite( $this->{server}{client}, $response );
        open my $fh, '<', $file;
        binmode $fh;

        while ( sysread( $fh, my $buffer, 4096 ) ) {
            syswrite( $this->{server}{client}, $buffer );
        }
        close $fh;
    }
    else {
        $this->returnError(404);
    }
}

sub handleFoswikiAction {
    my $this = shift;
    my %args = @_;      # method, uri_ref, proto, action, headers,
                        # path_info_ref, query_string_ref

    my $engine = $this->{server}{foswiki_engine_obj};
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

sub handleCgiScript {
    my $this = shift;
    my %args = @_;      # method, uri_ref, proto, headers, script,
                        # path_info_ref, query_string_ref
}

1;
