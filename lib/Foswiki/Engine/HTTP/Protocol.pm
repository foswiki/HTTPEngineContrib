package Foswiki::Engine::HTTP::Protocol;

use Net::Server::MultiType ();
@ISA = qw(Net::Server::MultiType);

use strict;
use HTTP::Message                 ();
use HTTP::Body                    ();
use HTTP::Status                  ();
use IO::Select                    ();
use Foswiki::Engine::HTTP::CGI    ();
use Foswiki::Engine::HTTP::Static ();

use Assert;
use Error qw(:try);

use Time::HiRes qw(time);
use Errno qw(EINTR EWOULDBLOCK EAGAIN);

my @sorted_actions = ();

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
}

$Foswiki::cfg{ScriptUrlPath} =~ s{/+$}{};
@sorted_actions =
  map { { action => $_, path => $Foswiki::cfg{ScriptUrlPaths}{$_} } } sort {
    length( $Foswiki::cfg{ScriptUrlPaths}{$b} ) <=>
      length( $Foswiki::cfg{ScriptUrlPaths}{$a} )
  } keys %{ $Foswiki::cfg{ScriptUrlPaths} }
  if exists $Foswiki::cfg{ScriptUrlPaths};

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
        qw(foswiki_read_headers_timeout foswiki_limit_request_line
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
    $opts->{foswiki_read_headers_timeout} = 30;
    $opts->{foswiki_read_body_timeout}    = 30 * 60;
    $opts->{foswiki_limit_request_line}   = 8192;
    $opts->{foswiki_limit_headers}        = 8192;
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

    try {
        ( $method, $uri, $proto, $headers ) = $this->readHeader();
    }
    catch Error::Simple with {
        my $e = shift;
    };

    unless ( defined $method && $method =~ /(?:POST|GET|HEAD)/i ) {
        $this->returnError(501);
        return;
    }

    if ( !defined($proto) || $proto =~ m!HTTP/0.9!i ) {
        $proto = 0.9;
    }
    elsif ( $proto =~ m!HTTP/(1\.[01])!i ) {
        $proto = $1;
    }
    else {
        $this->returnError(505);
        return;
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

        my ( $script, $path_info, $query_string ) =
          $uri     =~ m#^\Q$path\E/+([^/\?]+)([^\?]*)(?:\?(.*))?#;
        $path_info =~ s/%(..)/chr(hex($1))/ge;

        unless ( defined $script ) {
            $this->returnError(403);
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
        foreach my $entry (@sorted_actions) {
            next unless $uri =~ m#^\Q$entry->{path}\E(/[^\?]*)(?:\?(.*))?#;
            my ( $path_info, $query_string ) = ( $1, $2 );
            $path_info =~ s/%(..)/chr(hex($1))/ge;
            $this->handleFoswikiAction(
                method           => $method,
                uri_ref          => \$uri,
                proto            => $proto,
                headers          => $headers,
                action           => $entry->{action},
                path_info_ref    => \$path_info,
                query_string_ref => \$query_string,
            );
            $handled = 1;
            last;
        }
    }
    $this->returnError(404) unless $handled;
}

sub readHeader {
    my $this       = shift;
    my $sel        = IO::Select->new( $this->{server}{client} );
    my $timeleft   = $this->{server}{foswiki_read_headers_timeout};
    my $limit      = $this->{server}{foswiki_limit_request_line};
    my $bytes_read = 0;
    my $data       = '';
    my $state      = 'request';

    my $headers = HTTP::Headers->new();
    my ( $method, $uri, $proto );
    my ( $header, $hdrval );

  READ:
    while ( $state ne 'done' && $bytes_read < $limit && $timeleft > 0 ) {
        my $now   = time;
        my @ready = $sel->can_read($timeleft);
        $timeleft -= time - $now;
        if ( @ready == 0 ) {
            next if $! == EINTR;
            throw Error::Simple("EBADF: $!");
        }
        my $rv = sysread( $this->{server}{client}, my ($buffer), $limit );
        unless ( defined $rv ) {
            next if $! == EINTR || $! == EAGAIN || $! == EWOULDBLOCK;
            throw Error::Simple("EBADF: $!");
        }
        $bytes_read += $rv;
        while ( $state ne 'done' && length($buffer) > 0 ) {
            if ( $buffer =~ /(.*?)(?:\x0D?\x0A|\x0D(?!\x0A))/s ) {
                $data .= $1;
                substr( $buffer, 0, $+[0], '' );
                if ( $data =~ /^\s*$/s ) {
                    $headers->push_header( $header => $hdrval )
                      if defined $header
                          && defined $hdrval
                          && $state eq 'headers';
                    $state = 'done';
                    $this->{foswiki}{buffer} = $buffer;
                }
            }
            else {
                $data .= $buffer;
                next READ;
            }
            if ( $state eq 'request' ) {
                ( $method, $uri, $proto ) =
                  $data =~ /^\s*(\S+)\s+(\S+)(?:\s+(\S+))?/;
                $state = defined $proto
                  && $proto =~ m!HTTP/1\.[01]!i ? 'headers' : 'done';
                $limit      = $this->{server}{foswiki_limit_headers};
                $bytes_read = length($buffer);
            }
            elsif ( $state eq 'headers' ) {
                if ( $data =~ /^([^\s:]+)\s*:\s(.*)/ ) {
                    my @tmp = ( $1, $2 );
                    $headers->push_header( $header => $hdrval )
                      if defined $header && defined $hdrval;
                    ( $header, $hdrval ) = @tmp;
                }
                elsif ( $data =~ /^\s+(.*)/ ) {
                    $hdrval .= $1;
                }
            }
            $data = '';
        }
    }

    if ( $state eq 'done' ) {
        $this->{foswiki}{timeleft} = $timeleft;
        return ( $method, $uri, $proto, $headers );
    }
    elsif ( $timeleft <= 0 ) {
        throw Error::Simple('ETIMEOUT');
    }
    elsif ( $bytes_read >= $limit ) {
        throw Error::Simple('ESIZELIMIT');
    }
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

    while ( $bytes_read < $headers->content_length && $timeleft >= 0 ) {
        my $now   = time;
        my @ready = $sel->can_read($timeleft);
        $timeleft -= time - $now;
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
    my $handler = Foswiki::Engine::HTTP::Static->new(@_);
    $handler->send_response($this->{server}{client});
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
    my $handler = Foswiki::Engine::HTTP::CGI->new(@_);
    $handler->send_response($this->{server}{client});
}

1;
