
use strict;
use warnings;

use 5.010001;

use ExtUtils::MakeMaker 6.30;



my %WriteMakefileArgs = (
  "ABSTRACT" => "Minimalist POE IRC interface",
  "AUTHOR" => "Jon Portnoy <avenj\@cobaltirc.org>",
  "BUILD_REQUIRES" => {
    "Test::More" => "0.88"
  },
  "CONFIGURE_REQUIRES" => {
    "ExtUtils::MakeMaker" => "6.30"
  },
  "DISTNAME" => "POEx-IRC-Client-Lite",
  "EXE_FILES" => [],
  "LICENSE" => "perl",
  "NAME" => "POEx::IRC::Client::Lite",
  "PREREQ_PM" => {
    "Carp" => 0,
    "IRC::Toolkit" => "0.07",
    "Moo" => 1,
    "MooX::Role::POE::Emitter" => 0,
    "MooX::Role::Pluggable" => 0,
    "MooX::Types::MooseLike" => "0.15",
    "POE" => "1.3",
    "POE::Filter::IRCv3" => 0,
    "POEx::IRC::Backend" => "0.023",
    "namespace::clean" => 0,
    "strictures" => 1
  },
  "VERSION" => "0.001001",
  "test" => {
    "TESTS" => "t/*.t"
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



