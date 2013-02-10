package POEx::IRC::Client::Lite;
{
  $POEx::IRC::Client::Lite::VERSION = '0.001001';
}

use Carp 'confess';
use strictures 1;

use Moo;
use MooX::Types::MooseLike::Base ':all';
use POE;

use POEx::IRC::Backend;

use IRC::Message::Object 'ircmsg';
use IRC::Toolkit::Case;
use IRC::Toolkit::CTCP;

use POE::Filter::IRCv3;


has server => (
  required  => 1,
  is        => 'ro',
  isa       => Str,
  writer    => 'set_server',
);

has nick => (
  required  => 1,
  is        => 'ro',
  isa       => Str,
  writer    => 'set_nick',
);

after set_nick => sub {
  my ($self, $nick) = @_;
  if ($self->_has_conn && $self->conn->has_wheel) {
    ## Try to change IRC nickname as well.
    $self->nick($nick)
  }
};

has bindaddr => (
  lazy      => 1,
  is        => 'ro',
  isa       => Defined,
  writer    => 'set_bindaddr',
  predicate => 'has_bindaddr',
  default   => sub {
    my ($self) = @_;
    return '::0' if $self->has_ipv6 and $self->ipv6;
    return '0.0.0.0'
  },
);

has ipv6 => (
  lazy      => 1,
  is        => 'ro',
  isa       => Bool,
  writer    => 'set_ipv6',
  predicate => 'has_ipv6',
  default   => sub { 0 },
);

has pass => (
  lazy      => 1,
  is        => 'ro',
  isa       => Str,
  writer    => 'set_pass',
  predicate => 'has_pass',
  clearer   => 'clear_pass',
  default   => sub { '' },
);

has port => (
  lazy      => 1,
  is        => 'ro',
  isa       => Num,
  writer    => 'set_port',
  predicate => 'has_port',
  default   => sub { 6667 },
);

has realname => (
  lazy      => 1,
  is        => 'ro',
  isa       => Str,
  writer    => 'set_realname',
  predicate => 'has_realname',
  default   => sub { __PACKAGE__ },
);

has reconnect => (
  lazy      => 1,
  is        => 'ro',
  isa       => Num,
  writer    => 'set_reconnect',
  default   => sub { 120 },
);

has username => (
  lazy      => 1,
  is        => 'ro',
  isa       => Str,
  writer    => 'set_username',
  predicate => 'has_username',
  default   => sub { 'ircplug' },
);

### Typically internal:
has backend => (
  lazy    => 1,
  is      => 'ro',
  isa     => InstanceOf['POEx::IRC::Backend'],
  builder => '_build_backend',
);

sub _build_backend {
  my ($self) = @_;
  my $filter = POE::Filter::IRCv3->new(colonify => 0);
  POEx::IRC::Backend->new(filter_irc => $filter)
}

has conn => (
  lazy      => 1,
  weak_ref  => 1,
  is        => 'ro',
  isa       => Defined,
  writer    => '_set_conn',
  predicate => '_has_conn',
  clearer   => '_clear_conn',
);


with 'MooX::Role::POE::Emitter';
use MooX::Role::Pluggable::Constants;

sub BUILD {
  my ($self) = @_;

  $self->set_object_states(
    [
      $self => [ qw/
        ircsock_input
        ircsock_connector_open
        ircsock_connector_failure
        ircsock_disconnect
      / ],
      $self => {
        emitter_started => '_emitter_started',
        connect     => '_connect',
        disconnect  => '_disconnect',
        send        => '_send',
        privmsg     => '_privmsg',
        ctcp        => '_ctcp',
        notice      => '_notice',
        mode        => '_mode',
        join        => '_join',
        part        => '_part',
      },
      (
        $self->has_object_states ? @{ $self->object_states } : ()
      ),
    ],
  );

  $self->_start_emitter;
}

sub _emitter_started {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  $kernel->post( $self->backend->spawn->session_id, 'register' );
}

sub stop {
  my ($self) = @_;
  $poe_kernel->post( $self->backend->session_id, 'shutdown' );
  $self->_shutdown_emitter;
}

### ircsock_*

sub ircsock_connector_open {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $conn = $_[ARG0];

  $self->_set_conn( $conn );

  if ($self->process( 'preregister', $conn ) == EAT_ALL) {
    $self->_clear_conn;
    $self->emit( 'irc_connector_killed', $conn );
    return
  }

  my @pre;
  if ($self->has_pass && (my $pass = $self->pass)) {
    push @pre, ircmsg(
      command => 'pass',
      params  => [
        $pass
      ],
    )
  }
  $self->send(
    @pre,
    ircmsg(
      command => 'user',
      params  => [
        $self->username,
        '*', '*',
        $self->realname
      ],
    ),
    ircmsg(
      command => 'nick',
      params  => [ $self->nick ],
    ),
  );

  $self->emit( 'irc_connected', $conn );
}

sub ircsock_connector_failure {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $connector = $_[ARG0];
  my ($op, $errno, $errstr) = @_[ARG1 .. ARG3];

  $self->_clear_conn if $self->_has_conn;

  $self->emit( 'irc_connector_failed', @_[ARG0 .. $#_] );
  
  $self->timer( $self->reconnect, 'connect')
    unless !$self->reconnect;
}

sub ircsock_disconnect {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($conn, $str) = @_[ARG0, ARG1];
  
  $self->_clear_conn if $self->_has_conn; 
 
  $self->emit( 'irc_disconnected', $str );
}

sub ircsock_input {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($conn, $ircev) = @_[ARG0, ARG1];

  return unless $ircev->command;
  $self->emit( 'irc_'.lc($ircev->command), $ircev)
}


### Our IRC-related handlers.

sub N_irc_433 {
  ## Nickname in use.
  my (undef, $self) = splice @_, 0, 2;
  my $ircev = ${ $_[0] };

  my $taken = $ircev->params->[1] || $self->nick;

  $self->send(
    ircmsg(
      command => 'nick',
      params  => [ $taken . '_' ],
    )
  );

  EAT_NONE
}

sub N_irc_ping {
  my (undef, $self) = splice @_, 0, 2;
  my $ircev = ${ $_[0] };

  $self->send(
    ircmsg(
      command => 'pong',
      params  => [ @{ $ircev->params } ],
    )
  );

  EAT_NONE
}

sub N_irc_privmsg {
  my (undef, $self) = splice @_, 0, 2;
  my $ircev = ${ $_[0] };

  if (my $ctcp_ev = ctcp_extract($ircev)) {
    $self->emit_now( 'irc_'.$ctcp_ev->command, $ctcp_ev );
    return EAT_ALL
  }

  if ($ircev->has_tags && $ircev->get_tag('intent') eq 'ACTION') {
    $self->emit_now( 'irc_ctcp_action', $ircev );
    return EAT_ALL
  }

  my $prefix = substr $ircev->params->[0], 0, 1;
  if (grep {; $_ eq $prefix } ('#', '&', '+') ) {
    $self->emit_now( 'irc_public_msg', $ircev )
  } else {
    $self->emit_now( 'irc_private_msg', $ircev )
  }

  EAT_ALL
}

sub N_irc_notice {
  my (undef, $self) = splice @_, 0, 2;
  my $ircev = ${ $_[0] };

  if (my $ctcp_ev = ctcp_extract($ircev)) {
    $self->emit_now( 'irc_'.$ctcp_ev->command, $ctcp_ev );
    return EAT_ALL
  }

  EAT_NONE
}



### Public

## Since the retval of yield() is $self, many of these can be chained:
##  $client->connect->join(@channels)->privmsg(
##    join(',', @channels),  'hello!'
##  );

sub connect {
  my $self = shift;
  $self->yield( 'connect', @_ )
}

sub _connect {
  my ($kern, $self) = @_[KERNEL, OBJECT];
  
  $self->backend->create_connector(
    remoteaddr => $self->server,
    remoteport => $self->port,
    (
      $self->has_ipv6 ? (ipv6 => $self->ipv6) : ()
    ),
    (
      $self->has_bindaddr ? (bindaddr => $self->bindaddr) : ()
    ),
  );
}

sub disconnect {
  my $self = shift;
  $self->yield( 'disconnect', @_ )
}

sub _disconnect {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $message = $_[ARG0];
  $self->backend->send(
    ircmsg(
      command => 'quit',
      params  => [ $message ],
    ),
    $self->conn->wheel_id
  );
  $self->backend->disconnect( $self->conn->wheel->ID )
    if $self->_has_conn and $self->conn->has_wheel;
}

sub send_raw_line {
  my ($self, $line) = @_;
  $self->send( ircmsg(raw_line => $line) );
}

sub send {
  my $self = shift;
  $self->yield( 'send', @_ )
}

sub _send {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  for my $outev (@_[ARG0 .. $#_]) {
    if ($self->process( 'outgoing', $outev ) == EAT_ALL) {
      next
    }
    $self->backend->send( $outev, $self->conn->wheel_id )
  }
}

## Sugar, and POE-dispatchable counterparts.
sub notice {
  my $self = shift;
  $self->yield( 'notice', @_ )
}

sub _notice {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($target, @data) = @_[ARG0 .. $#_];
  $self->send(
    ircmsg(
      command => 'notice',
      params  => [ $target, join ' ', @data ]
    )
  )
}

sub privmsg {
  my $self = shift;
  $self->yield( 'privmsg', @_ )
}

sub _privmsg {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($target, @data) = @_[ARG0 .. $#_];
  $self->send(
    ircmsg(
      command => 'privmsg',
      params  => [ $target, join ' ', @data ]
    )
  )
}

sub ctcp {
  my $self = shift;
  $self->yield( 'ctcp', @_ )
}

sub _ctcp {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($type, $target, @data) = @_[ARG0 .. $#_];
  my $line = join ' ', uc($type), @data;
  my $quoted = ctcp_quote($line);
  $self->send(
    ircmsg(
      command => 'privmsg',
      params  => [ $target, $quoted ]
    )
  )
}

sub mode {
  my $self = shift;
  $self->yield( 'mode', @_ )
}

sub _mode {
  my ($kernel, $self)    = @_[KERNEL, OBJECT];
  my ($target, $modestr) = @_[ARG0, ARG1];
  ## FIXME genericize IRC::Server::Pluggable::IRC::Mode* classes
  ##  move to IRC::Toolkit objs
  ##  accept them here:
  $self->send(
    ircmsg(
      command => 'mode',
      params  => [ $target, $modestr ],
    )
  )
}

sub join {
  my $self = shift;
  $self->yield( 'join', @_ )
}

sub _join {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $join_to = CORE::join ',', @_[ARG0 .. $#_];
  $self->send(
    ircmsg(
      command => 'join',
      params  => [ $join_to ],
    )
  )
}

sub part {
  my $self = shift;
  $self->yield( 'part', @_ )
}

sub _part {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($channel, $msg) = @_[ARG0, ARG1];
  $self->send(
    ircmsg(
      command => 'part',
      params  => [ $channel, $msg ],
    )
  );
}

1;

=pod

=head1 NAME

POEx::IRC::Client::Lite - Minimalist POE IRC interface

=head1 SYNOPSIS

  package MyClient;
  use POE;
  use POEx::IRC::Client::Lite;
  use IRC::Toolkit;

  my @channels = ( '#otw', '#eris' );

  POE::Session->create(
    package_states => [
      MyClient => [ qw/
        _start
        recv_irc_001
        recv_irc_public_msg
        recv_irc_ctcp_version
      / ],
    ],
  );

  sub _start {
    my ($kern, $heap) = @_[KERNEL, HEAP];

    $heap->{irc} = POEx::IRC::Client::Lite->new(
      event_prefix => 'recv_',
      server  => $server,
      nick    => $nickname,
      username => $username,
    );

    $heap->{irc}->connect;
  }

  sub recv_irc_001 {
    my ($kern, $heap) = @_[KERNEL, HEAP];

    $heap->{irc}->join(@channels)->privmsg(
      join(',', @channels), "hello!"
    );
  }

  sub recv_irc_public_msg {
    my ($kern, $heap) = @_[KERNEL, HEAP];
    my $event = $_[ARG0];

    my ($target, $string) = @{ $event->params };
    my $from = parse_user( $event->prefix );

    if (lc($string||'') eq 'hello') {
      $heap->{irc}->privmsg($target, "hello there, $from")
    }
  }

  sub recv_irc_ctcp_version {
    my ($kern, $heap) = @_[KERNEL, HEAP];
    my $event = $_[ARG0];

    my $from = parse_user( $event->prefix );

    $heap->{irc}->notice( $from =>
      ctcp_quote("VERSION a silly Client::Lite example")
    );
  }

=head1 DESCRIPTION

A light-weight, pluggable IRC client library using L<POEx::IRC::Backend> and
L<IRC::Toolkit>.

No state is maintained; POEx::IRC::Client::Lite provides a
minimalist interface to IRC and serves as a base class for stateful clients.

This is early development software pulled out of a much larger in-progress
project.

B<< See L<POE::Component::IRC> for a more mature POE IRC client library. >>

=head2 new

  my $irc = POEx::IRC::Client::Lite->new(
    event_prefix => $prefix,
    server    => $server,
    nick      => $nickname,
    username  => $username,
  );

Create a new Client::Lite instance. Optional arguments are:

=over

=item bindaddr

Local address to bind to.

=item ipv6

Boolean value indicating whether to prefer IPv6.

=item port

Remote port to use (defaults to 6667).

=item reconnect

Reconnection attempt delay, in seconds.

=back

=head2 stop

  $irc->stop;

Disconnect, stop the Emitter, and purge the plugin pipeline.

=head2 IRC Methods

IRC-related methods can be called via normal method dispatch or sent as a POE
event:

  ## These are equivalent:
  $irc->send( $ircevent );
  $irc->yield( 'send', $ircevent );
  $poe_kernel->post( $irc_session_id, 'send', $ircevent );

Methods that dispatch to IRC return C<$self>, so they can be chained:

  $irc->connect->join(@channels)->privmsg(
    join(',', @channels),
    'hello there!'
  );

=head2 connect

  $irc->connect;

Attempt an outgoing connection.

=head2 disconnect

  $irc->disconnect($message);

Quit IRC and shut down the wheel.

=head2 send

  use IRC::Message::Object 'ircmsg';
  $irc->send(
    ircmsg(
      command => 'oper',
      params  => [ $user, $passwd ],
    )
  );

  ## ... or a raw HASH:
  $irc->send(
    {
      command => 'oper',
      params  => [ $user, $passwd ],
    }
  )

  ## ... or a raw line:
  $irc->send_raw_line('PRIVMSG avenj :some things');

Use C<send()> to send an L<IRC::Message::Object> or a compatible
HASH; this method will also take a list of events in either of those formats.

Use C<send_raw_line()> to send a single raw IRC line. This is rarely a good
idea; L<POEx::IRC::Backend> provides an IRCv3-capable filter.

=head2 privmsg

  $irc->privmsg( $target, $string );

Sends a PRIVMSG to the specified target.

=head2 notice

  $irc->notice( $target, $string );

Sends a NOTICE to the specified target.

=head2 ctcp

  $irc->ctcp( $target, $type, @params );

Encodes and sends a CTCP B<request> to the target.
(To send a CTCP B<reply>, send a L</notice> that has been quoted via
L<IRC::Toolkit::CTCP/"ctcp_quote">.)

=head2 mode

  $irc->mode( $channel, $modestring );

Sends a MODE for the specified target.

=head2 join

  $irc->join( $channel );

Attempts to join the specified channel.

=head2 part

  $irc->part( $channel, $message );

Attempts to leave the specified channel with an optional PART message.


=head1 Emitted Events

All IRC events are emitted as 'irc_$cmd' e.g. 'irc_005' (ISUPPORT) or
'irc_mode' with a few notable exceptions, detailed below.

C<$_[ARG0]> is the L<IRC::Message::Object>.

=head2 irc_private_message

Emitted for PRIVMSG-type messages not covered by L</irc_public_message>.

=head2 irc_public_message

Emitted for PRIVMSG-type messages that appear to be destined for a channel
target.

=head2 irc_ctcp

Emitted for incoming CTCP requests.

C<$_[ARG0]> is the L<IRC::Message::Object> produced by
L<IRC::Toolkit::CTCP/ctcp_extract>.

An example of sending a CTCP reply lives in L</SYNOPSIS>.
See L<IRC::Toolkit::CTCP> for CTCP-related helpers.

=head2 irc_ctcpreply

Emitted for incoming CTCP replies.

Mirrors the behavior of L</irc_ctcp>

=head1 Pluggable Events

These are events explicitly dispatched to plugins 
via L<MooX::Role::POE::Emitter/process>; 
see L<MooX::Role::POE::Emitter> and L<MooX::Role::Pluggable> for more on
making use of plugins.

=head2 preregister

Dispatched to plugins when an outgoing connection has been established, 
but prior to registration.

The first argument is the L<POEx::IRC::Backend::Connect> object.

Returning EAT_ALL (see L<MooX::Role::Pluggable::Constants>) to Client::Lite
will terminate the connection without registering.

=head2 outgoing

Dispatched to plugins prior to sending output.

The first argument is the item being sent. Note that no sanity checks are
performed on the item(s) at this stage (this is done after items are passed to
the L<POEx::IRC::Backend> instance) -- your plugin's handler could receive a
HASH, an L<IRC::Message::Object>, a raw line, or something invalid.

Returning EAT_ALL will skip sending the item.

=head1 SEE ALSO

L<POE::Component::IRC>, a fully-featured POE IRC client library

L<IRC::Toolkit>

L<POEx::IRC::Backend>

L<POE::Filter::IRCv3>

L<MooX::Role::POE::Emitter>

L<MooX::Role::Pluggable>

=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org>

=cut
