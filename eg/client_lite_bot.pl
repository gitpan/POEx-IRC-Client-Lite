#!/usr/bin/env perl
use strictures 1;

my $nickname = 'litebot';
my $username = 'clientlite';
my $server   = 'irc.cobaltirc.org';
my @channels = ( '#eris', '#botsex' );

use POE;
use IRC::Toolkit;
use POEx::IRC::Client::Lite;

POE::Session->create(
  package_states => [
    main => [ qw/
      _start
      cli_irc_public_msg
      cli_irc_ctcp_version
      cli_irc_001
    / ],
  ],
);
$poe_kernel->run;

sub _start {
  my ($kern, $heap) = @_[KERNEL, HEAP];
  $heap->{irc} = POEx::IRC::Client::Lite->new(
    event_prefix => 'cli_',
    server   => $server,
    nick     => $nickname,
    username => $username,
  )->connect()
}

sub cli_irc_001 {
  my ($kern, $heap, $ev) = @_[KERNEL, HEAP, ARG0];

  ## Chainable methods.
  my $irc = $heap->{irc};
  $irc->join(@channels)->privmsg(join(',', @channels), "hello there!");
}

sub cli_irc_public_msg {
  my ($kern, $heap, $ev) = @_[KERNEL, HEAP, ARG0];
  my ($target, $string)  = @{ $ev->params };

  if (lc($string || '') eq 'hello') {
    $heap->{irc}->privmsg($target, "hello, world!");
  }
}

sub cli_irc_ctcp_version {
  my ($kern, $heap, $ev) = @_[KERNEL, HEAP, ARG0];

  my $from = parse_user( $ev->prefix );

  $heap->{irc}->notice( $from,
    ctcp_quote("VERSION a silly POEx::IRC::Client::Lite example"),
  );
}

