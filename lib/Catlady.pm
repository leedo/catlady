package Catlady;

use strict;
use warnings;

use v5.10;

use Alice;
use AnyEvent;
use AnyEvent::DBI::Abstract;
use List::Util qw/shuffle/;
use Catlady::HTTPD;
use Path::Class;
use Text::MicroTemplate::File;
use FindBin;
use Any::Moose;

has [qw/
      salt secret cookie domain db_user db_pass dsn
      port address db_attr default_server static_prefix
      image_prefix configs sharedir
    /] => (
  is => 'ro',
  required => 1,
);

has dbi => (
  is => 'ro',
  lazy => 1,
  default => sub {
    my $self = shift;
    my $dbi = AnyEvent::DBI::Abstract->new(
      $self->dsn, $self->db_user, $self->db_pass,
      AutoCommit => 1, PrintError => 1, %{ $self->db_attr },
    );
    for my $attr (keys %{$self->db_attr}) {
      next if $attr eq "exec_server";
      $dbi->attr($attr, $self->db_attr->{$attr}, sub {});
    }
    return $dbi;
  }
);

has cats => (
  is => 'ro',
  default => sub {{}},
);

sub add_cat {$_[0]->cats->{$_[1]} = $_[2]}
sub get_cat {$_[0]->cats->{$_[1]}}
sub remove_cat {delete $_[0]->cats->{$_[1]}}
sub all_cats {values %{$_[0]->cats}}
sub cat_names {keys %{$_[0]->cats}}
sub has_cats {keys %{$_[0]->cats} > 0}

sub stream_count {
  my ($self, $cat_name) = @_;
  if ($cat_name and my $cat = $self->get_cat($cat_name)) {
    return scalar @{$cat->streams};
  }
  return scalar grep {@{$_->streams}} $self->all_cats;
}

sub connected_users {
  my $self = shift;
  return grep {@{$self->get_cat($_)->streams}} $self->cat_names;
}

has httpd => (
  is => 'ro',
  lazy => 1,
  default => sub {
    my $self = shift;
    AE::log info => "listening on port ".$self->port;
    Catlady::HTTPD->new(
      address => $self->address,
      port => $self->port,
      catlady => $self,
      assets => $self->sharedir,
    );
  }
);

has timestamps => (
  is => 'rw',
  default => sub {{}},
);

has template => (
  is => 'ro',
  lazy => 1,
  default => sub {
    my $self = shift;
    Text::MicroTemplate::File->new(
      include_path =>  [
        "$FindBin::Bin/../templates",
        $self->sharedir . "/templates",
      ],
      cache => 1,
    );
  },
);

sub BUILD {
  my $self = shift;
  $self->start_idle_timer;
  $self->start_murder_timer;
}

sub touch {
  my ($self, $cat) = @_;
  $self->timestamps->{$cat->user} = time;
}

sub start_idle_timer {
  my $self = shift;
  $self->{idle_t} = AE::timer 0, 60 * 5, sub {
    for my $cat ($self->all_cats) {
      if (my $t = $self->timestamps->{$cat->user}) {
        $self->dbi->update('users', {last_login => $t}, {id => $cat->user}, sub {});
      }
    }
  };
}

sub start_murder_timer {
  my $self = shift;
  # check every hour for alices that have been idle too long
  $self->{murder_t} = AE::timer 0, 60 * 60, sub {
    my $day = 60 * 60 * 24;
    my $now = time;
    my %murder_table = (
      1 => $now - ($day * 2),
      2 => $now - ($day * 7),
      3 => $now - ($day * 14),
      4 => $now - ($day * 21),
    );
    for my $level (keys %murder_table) {
      my $limit = $murder_table{$level};
      $self->dbi->select('users', [qw/username/], {sub_level => $level, last_login => {'<' => $limit}, disabled => 0}, sub {
        my ($dbh, $rows, $rv) = @_;

        for my $row (@$rows) {
          my ($username) = @$row;
          AE::log info => "$username is idle... shutting down";
          $self->murder_cat($username);
        }
      });
    }
  };
}

sub revive_cats {
  my $self = shift;
  AE::log info => "reviving cats using configs in ".$self->configs;
  $self->dbi->select('users', [qw/username id/], {disabled => 0}, sub {
    my ($dbh, $rows, $rv) = @_;

    $rows = [ shuffle @$rows ];

    my $timer; $timer = AE::timer 0, 5, sub {

      if (!@$rows) {
        undef $timer;
        return;
      }

      my $row = shift @$rows;
      my ($user, $userid) = @$row;

      return if $self->get_cat($user);

      $self->revive_cat($user, $userid);
    };
  });
}

sub murder_cat {
  my ($self, $user) = @_;
  if (my $alice = $self->get_cat($user)) {
    AE::log info => "murdering $user\'s cat";
    $alice->init_shutdown(sub{$self->remove_cat($user)});
    $self->dbi->update('users', {disabled => 1}, {id => $alice->user}, sub {});
    delete $self->timestamps->{$alice->user};
  }
}

sub revive_cat {
  my ($self, $user, $userid, $cb) = @_;

  if (!$user or !$userid) {
    AE::log error => "need user and userid to revive user";
    return;
  }

  if ($self->get_cat($user)) {
    AE::log error => "$user cat is already alive";
    return;
  }

  AE::log info => "reviving $user\'s cat";

  Alice::Config->new(
    path       => $self->config($user),
    static_prefix => $self->static_prefix,
    image_prefix => $self->image_prefix,
    auth       => {user => $user, pass => "dummy"}, # auth->{user} is needed elsewhere :(
  )->load(sub {
    my $config = shift;
    my $alice = Alice->new(
      config   => $config,
      template => $self->template,
      user     => $userid,
      dbi      => $self->dbi,
    );

    if ($alice->config->first_run) {
      my %default = %{ $self->default_server };
      $default{autoconnect} = "on";
      $default{nick} = $user;
      $alice->config->servers({$default{name} => \%default});
    }

    $self->dbi->update('users', {disabled => 0}, {id => $userid}, sub {});
    $alice->run;

    $self->add_cat($user, $alice);
    $self->timestamps->{$userid} = time;
    $cb->($alice) if $cb;
  });
}

sub run {
  my $self = shift;

  $self->{cv} = AE::cv;
  $self->{sig} = AE::signal INT => sub {$self->{cv}->send};

  $self->httpd;
  $self->revive_cats;

  $self->{cv}->recv;

  $self->shutdown;
  AE::log info => "shutdown complete";
  exit 0;
}

sub shutdown {
  my ($self, $msg) = @_;

  AE::log info => "shutting down";

  return unless $self->has_cats;

  my @timers;
  my $cv = AE::cv;

  for my $name ($self->cat_names) {
    AE::log info => "shutting down $name";

    $cv->begin;

    my $t = AE::timer 6, 0, sub {
      AE::log warn => "force shut down $name";
      $self->remove_cat($name);
      $cv->end;
    };
    push @timers, $t;

    $self->get_cat($name)->init_shutdown(sub {
      AE::log info => "shut down $name";
      undef $t;
      $self->remove_cat($name);
      $cv->end;
    }, $msg);
  }
  $cv->recv;
}

sub summon_cat {
  my ($self, $owner) = @_;
  my $alice = $self->get_cat($owner);
  if (!$alice) {
    $self->dbi->select('users', [qw/username id/],
      {username => $owner},
      sub {
        my ($dbh, $rows, $rv) = @_;
        if (@$rows) {
          my ($user, $userid) = @{$rows->[0]};
          $self->revive_cat($user, $userid);
        }
        else {
          AE::log warn => "$owner isn't in the database";
        }
      }
    );
  }
  else {
    AE::log warn => "$owner already has a cat running";
  }
}

sub config {
  my ($self, $owner) = @_;
  dir($self->configs)->stringify . "/$owner";
}

__PACKAGE__->meta->make_immutable;
1;
