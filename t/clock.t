#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use ok 'Cache::Ref::CLOCK';

my $c = Cache::Ref::CLOCK->new( size => 3 );

isa_ok( $c, "Cache::Ref" );

$c->set( foo => "blah" );
is( $c->get("foo"), "blah", "foo" );

$c->set( bar => "lala" );
is( $c->get("bar"), "lala", "bar" );

$c->set( baz => "blob" );
is( $c->get("baz"), "blob", "baz" );

$c->set( zot => "quxx" );
is( $c->get("zot"), "quxx", "zot" );

is( $c->get("bar"), "lala", "bar still in cache" );

is( $c->get("foo"), undef, "foo no longer in cache" );

$c->set( quxx => "dancing" );

is( $c->get("bar"), "lala", "bar still in cache" );
is( $c->get("baz"), undef, "baz no longer in cache" );
is( $c->get("zot"), "quxx", "zot still in cache" );
is( $c->get("quxx"), "dancing", "quxx still in cache" );

{
    my ( $hit, $miss ) = ( 0, 0 );

    for ( 1 .. 2000 ) {
        my $key = 1 + int rand 5;
        if ( $c->get($key) ) {
            $hit++;
        } else {
            $miss++;
            $c->set($key => $key);
        }
    }

    cmp_ok( $hit, '>=', $miss, "more cache hits than misses during random access of small sigma ($hit >= $miss)" );
}

$c->clear;

{
    my ( $hit, $miss ) = ( 0, 0 );

    for ( 1 .. 100 ) {
        foreach my $key ( 1 .. 10 ) {
            if ( $c->get($key) ) {
                $hit++;
            } else {
                $miss++;
                $c->set($key => $key);
            }
        }
    }

    is( $hit, 0, "no hits during linear scans" );
}


done_testing;

# ex: set sw=4 et:

