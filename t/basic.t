#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 16;
use Test::Mojo;

use_ok( 'Carp' );
use_ok( 'Config' );
use_ok( 'DBI' );
use_ok( 'Date::Simple' );
use_ok( 'Digest::MD5' );
use_ok( 'Email::Sender::Simple' );
use_ok( 'Email::Simple' );
use_ok( 'Email::Valid' );
use_ok( 'Encode' );
use_ok( 'English' );
use_ok( 'File::Spec' );
use_ok( 'Mojolicious' );
use_ok( 'Pg::Explain' );
use_ok( 'Explain' );

my $t = Test::Mojo->new( 'Explain' );

$t->get_ok( '/' )->status_is( 200 );
