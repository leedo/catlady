package Catlady;

use strict;
use warnings;

use 5.010;

use constant DB_USER => "usealice";
use constant DB_PASS => "usealice";

use AnyEvent::Strict;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::DBI::Abstract;
use List::Util qw/shuffle/;
use Catlady::HTTPD;
use Path::Class;
use Text::MicroTemplate::File;
use FindBin;
use Any::Moose;

with any_moose 'X::Getopt';

has configs => (
  is => 'rw',
  isa => 'Str',
  required => 1,
  default => "$FindBin::Bin/../etc/users",
);

has dsn => (
  is => 'ro',
  default => sub {
    [
      "DBI:mysql:dbname=usealice;host=localhost;port=3306;mysql_auto_reconnect=1;mysql_enable_utf8=1",
      DB_USER, DB_PASS,
      AutoCommit => 1, PrintError => 1, exec_server => 1, mysql_enable_utf8 => 1, mysql_auto_reconnect => 1,
    ];
  }
);

has dbi => (
  is => 'ro',
  isa => 'AnyEvent::DBI',
  lazy => 1,
  default => sub {
    my $self = shift;
    my $dbi = AnyEvent::DBI::Abstract->new(@{$self->dsn});
    $dbi->attr("mysql_auto_reconnect", 1, sub {});
    $dbi->attr("mysql_enable_utf8", 1, sub {});
    return $dbi;
  }
);

has sock => (
  is => 'ro',
  isa => 'Str',
  default => sub {
    my $sock = "./var/control.sock";
    die "sock file exists\n" if -e $sock;
    return $sock;
  }
);

has cats => (
  is => 'rw',
  isa => 'HashRef[Alice]',
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
  isa => 'Catlady::HTTPD',
  lazy => 1,
  default => sub {
    my $self = shift;
    print STDERR "listening on port ".$self->port."\n";
    Catlady::HTTPD->new(
      address => '0.0.0.0',
      port => $self->port,
      catlady => $self,
      assets => "$FindBin::Bin/../share/",
    );
  }
);

has port => (
  is => 'rw',
  isa => 'Str',
  default => 9000,
);

has timestamps => (
  is => 'rw',
  isa => 'HashRef',
  default => sub {{}},
);

has 'template' => (
  is => 'ro',
  isa => 'Text::MicroTemplate::File',
  lazy => 1,
  default => sub {
    Text::MicroTemplate::File->new(
      include_path =>  [
        "$FindBin::Bin/../templates",
        "$FindBin::Bin/../share/templates",
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

sub reload_module {
  my ($self, $module) = @_;
  my @path = split /::/, $module;
  delete $INC{join("/", @path). ".pm"};
  require $module;
  $module->import;
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
          print STDERR "$username is idle... shutting down\n";
          $self->murder_cat($username);
        }
      });
    }
  };
}

sub revive_cats {
  my $self = shift;
  print STDERR "reviving cats using configs in ".$self->configs."\n";
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
      return unless -e $self->config($user);

      $self->revive_cat($user, $userid);
    };
  });
}

sub murder_cat {
  my ($self, $user) = @_;
  if (my $alice = $self->get_cat($user)) {
    print STDERR "murdering $user\'s cat\n";
    $alice->init_shutdown(sub{$self->remove_cat($user)});
    $self->dbi->update('users', {disabled => 1}, {id => $alice->user}, sub {});
    delete $self->timestamps->{$alice->user};
  }
}

sub revive_cat {
  my ($self, $user, $userid, $cb) = @_;

  die "need user and userid to revive user" unless $user and $userid;
  die "$user cat is already alive" if $self->get_cat($user);

  say "reviving $user\'s cat";

  Alice::Config->new(
    path       => $self->config($user),
    static_prefix => "https://static.usealice.org/",
    image_prefix => "https://noembed.com/i/",
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
      $alice->config->servers({alice => $self->default_server($user)});
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
  $self->listen;

  $self->{cv}->recv;

  $self->shutdown;
  print STDERR "shutdown complete\n";
  exit 0;
}

sub shutdown {
  my ($self, $msg) = @_;

  print STDERR "shutting down\n";
  unlink $self->sock;

  return unless $self->has_cats;

  my @timers;
  my $cv = AE::cv;

  for my $name ($self->cat_names) {
    print STDERR " shutting down $name\n";

    $cv->begin;

    my $t = AE::timer 6, 0, sub {
      print STDERR "  force shut down $name\n";
      $self->remove_cat($name);
      $cv->end;
    };
    push @timers, $t;

    $self->get_cat($name)->init_shutdown(sub {
      print STDERR "  shut down $name\n";
      undef $t;
      $self->remove_cat($name);
      $cv->end;
    }, $msg);
  }
  $cv->recv;
}

sub listen {
  my $self = shift;
  tcp_server "unix/", $self->sock, sub {
    my ($fh, $host, $port) = @_;
    my $handle;
    $handle = AnyEvent::Handle->new(fh => $fh, on_eof => sub{$handle->destroy});
    $handle->push_read(line => sub {
      my (undef, $line) = @_; 
      my ($command, @args) = split /\s+/, $line;
      my $ret = "nothing";
      given ($command) {
        when ('summon') {
          $self->summon_cat($args[0]);
          $ret = 'livecat';
        }
        when ('murder') {
          $self->murder_cat($args[0]);
          $ret = 'dedcat';
        }
        when ('shutdown') {
          $self->shutdown(join " ", @args);
          $ret = 'shutdown';
        }
        when ('alert') {
          for ($self->all_cats) {
            $_->alert(join " ", @args);
          }
          $ret = 'alerted';
        }
      }
      $handle->push_write("$ret\015\012");
      $handle->on_drain(sub{undef $handle});
    });
  };
  say STDERR "herding cats on ".$self->sock;
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
          say STDERR "$owner isn't in the database";
        }
      }
    );
  }
  else {
    say STDERR "$owner already has a cat running";
  }
}

sub config {
  my ($self, $owner) = @_;
  dir($self->configs)->stringify . "/$owner";
}

sub default_server {
  my ($self, $owner) = @_;
  {
    name => "alice",
    host => "irc.usealice.org",
    port => 6767,
    nick => $owner,
    autoconnect => "on",
    channels => ["#alice"],
  }
}

__PACKAGE__->meta->make_immutable;
1;
