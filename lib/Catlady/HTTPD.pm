package Catlady::HTTPD;

use Alice;
use AnyEvent;
use Plack::Builder;
use Any::Moose;
use Digest::SHA1 qw/sha1_hex/;
use Plack::Middleware::Session;
use Plack::Session::State::Cookie;

extends 'Alice::HTTP::Server';

has catlady => (
  is  => 'ro',
  isa => 'Catlady',
  required => 1,
);

has app => (
  is => 'rw',
  isa => 'Alice|Undef',
);

has '+ping' => (
  is => 'rw',
  lazy => 1,
  default => sub {
    my $self = shift;
    AE::timer 5, 5, sub {
      my @streams = map {@{$_->streams}} $self->catlady->all_cats;
      my $message = [{type => "action", event => "ping"}];
      my $idle_w; $idle_w = AE::idle sub {
        if (my $stream = shift @streams) {
          $stream->send($message);
          return;
        }
        undef $idle_w;
      };
    };
  }
);

sub _build_httpd {
  my $self = shift;
  my $httpd = Fliggy::Server->new(
    host => $self->address,
    port => $self->port,
  );
  $httpd->register_service($self->_build_app);
  $self->httpd($httpd);
}

sub _build_app {
  my $self = shift;

  my $expires =  60 * 60 * 24 * 7;

  builder {
    enable "Static", path => qr{^/static/}, root => $self->assets;
    enable "ReverseProxy";
    enable "+Catlady::Middleware::Session::Cookie",
      secret => $self->catlady->secret,
      session_key => $self->catlady->cookie,
      domain => $self->catlady->domain,
      expires => $expires,
    ;
    enable "+Alice::HTTP::WebSocket";
    sub {
      my $env = shift;
      return sub {
        $self->dispatch($env, shift);
      }
    }
  };
}

sub auth_enabled { 1 }

sub authenticate {
  my ($self, $user, $pass, $cb) = @_;
  $user ||= "";
  $pass ||= "";

  $pass = sha1_hex "$pass-" . $self->catlady->salt;

  $self->catlady->dbi->select('users', [qw/id/],
    {username => $user, password => $pass},
    sub {
      my ($dbh, $rows, $rv) = @_;

      # invalid user/pass
      if (!@$rows) {
        $cb->();
        return;
      }

      my ($userid) = @{$rows->[0]};
      my $cat = $self->catlady->get_cat($user);
      return $cb->($cat) if $cat;

      $self->catlady->revive_cat($user, $userid, $cb);
    }
  );
}

sub is_logged_in {
  my ($self, $req) = @_;
  my $session = $req->env->{'psgix.session'};

  return 0 unless $session->{is_logged_in}
              and my $user = $session->{username};

  if (my $cat = $self->catlady->get_cat($user)) {
    $self->catlady->touch($cat);
    $self->app($cat);
    return 1;
  }

  return 0;
}

sub render {
  my $self = shift;
  if ($self->app) {
    $self->app->render(@_);
  } else {
    Alice::render($self->catlady, @_);
  }
}

1;
