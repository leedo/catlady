package Catlady::Middleware::Session::Cookie;

use strict;
use parent qw(Plack::Middleware::Session::Cookie);

use JSON::XS;
use Plack::Util::Accessor qw(serializer deserializer);

sub prepare_app {
  my $self = shift;
  $self->SUPER::prepare_app;

  $self->serializer(sub {MIME::Base64::encode(JSON::encode_json($_[0]), '' )})
    unless $self->serializer;

  $self->deserializer(sub {JSON::decode_json(MIME::Base64::decode($_[0]))})
    unless $self->deserializer; 
}

sub get_session {
  my($self, $request) = @_;

  my $cookie = $self->state->get_session_id($request) or return;

  my ($b64, $sig) = split /--/, $cookie, 3;
  $self->sig($b64) eq $sig or return;

  my $session = $self->deserializer->($b64);
  return ($self->generate_id, $session);
}

sub _serialize {
  my($self, $id, $session) = @_;

  $session->{session_id} = $id;

  my $b64 = $self->serializer->($session);
  join "--", $b64, $self->sig($b64);
}

1;
