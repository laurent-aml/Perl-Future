use v5.10;
use strict;
use warnings;

use Test2::V0;

use Future;

# A Future subclass with a controllable asynchronous teardown, hooked in via
# _safe_cancel_cleanup. Stands in for something like Future::With's guard.
package CleanupFuture {
   our @ISA = ( 'Future' );

   # Use set_udata/udata rather than the instance as a hash, so this helper
   # works under both the pure-perl and the XS backend.
   sub with_gate {
      my ( $self, $gate, $ranref ) = @_;
      $self->set_udata( cg_gate => $gate );
      $self->set_udata( cg_ran  => $ranref );
      return $self;
   }

   sub _safe_cancel_cleanup {
      my $self = shift;
      my $gate = $self->udata( "cg_gate" ) or return;
      my $ranref = $self->udata( "cg_ran" );
      return $gate->then( sub { $$ranref = 1; Future->done } );
   }
}

# A plain pending Future has no asynchronous cleanup, so safe_cancel behaves
# like a prompt cancel and hands back an already-complete Future.
{
   my $f = Future->new;

   my $cf = $f->safe_cancel;

   ok( $cf->is_ready,    'safe_cancel of a plain future returns a ready Future' );
   ok( $f->is_cancelled, 'plain future is cancelled by safe_cancel' );
}

# safe_cancel of an already-ready future is a harmless no-op.
{
   my $f = Future->new;
   $f->done( "x" );

   my $cf = $f->safe_cancel;
   ok( $cf->is_ready,  'safe_cancel of a ready future returns a ready Future' );
   ok( !$f->is_cancelled, 'an already-done future is not cancelled' );
}

# safe_cancel propagates to a chained child, awaits its async cleanup to
# completion, and only then cancels - parent before child.
{
   my $ran  = 0;
   my $gate = Future->new;
   my $child  = CleanupFuture->new->with_gate( $gate, \$ran );
   my $parent = Future->new;

   # Stand in for what Future::AsyncAwait wires at a suspend point.
   $parent->AWAIT_CHAIN_CANCEL( $child );
   $parent->AWAIT_CHAIN_SAFE_CANCEL( $child );

   my $parent_cancelled_when_child_done;
   $child->on_ready( sub { $parent_cancelled_when_child_done = $parent->is_cancelled } );

   my $cf = $parent->safe_cancel;

   ok( !$cf->is_ready,     'cleanup Future pending while child cleanup runs' );
   ok( !$parent->is_ready, 'parent pending' );
   ok( !$child->is_ready,  'child pending' );
   is( $ran, 0,            'child async cleanup not yet run' );

   $gate->done;

   ok( $cf->is_ready,        'cleanup Future completes once child cleanup finishes' );
   is( $ran, 1,              'child async cleanup ran to completion' );
   ok( $parent->is_cancelled, 'parent is cancelled' );
   ok( $child->is_cancelled,  'child is cancelled' );

   ok( $parent_cancelled_when_child_done,
      'parent was already cancelled when the child cancelled (ordering)' );
}

done_testing;
