package Cache::Ref::CAR::Base;
use Moose::Role;

use namespace::autoclean;

sub REF_BIT ()         { 0x01 }
sub MFU_HISTORY_BIT () { 0x02 }
sub LONG_TERM_BIT ()   { 0x04 }

requires qw(
    _mru_history_too_big
    _mfu_history_too_big

    _restore_from_mfu_history
    _restore_from_mru_history

    _clear_additional

    _decrease_mru_target_size
    _increase_mru_target_size

    _expire
);

with (
    qw(
        Cache::Ref::Role::API
        Cache::Ref::Role::Index
    ),
    map {
        ('Cache::Ref::Role::WithDoublyLinkedList' => { # FIXME can it just be circular too?
            name => $_,
            value_offset => 1, # the cache key
            next_offset => 3,
            prev_offset => 4,
        }),
    } qw(_mru_history _mfu_history), # b1, b2
);

sub _next { $_[1][3] }
sub _set_next {
    my ( $self, $node, $next ) = @_;
    $node->[3] = $next;
}

sub _prev { $_[1][4] }
sub _set_prev {
    my ( $self, $node, $prev ) = @_;
    $node->[4] = $prev;
}

has size => (
    isa => "Int",
    is  => "ro",
    required => 1,
);

foreach my $pool qw(mfu mru) { # t1, t2
    has "_$pool" => ( is => "rw" ); # circular linked list tail

    foreach my $counter qw(size history_size) {
        has "_${pool}_$counter" => (
            #traits => [qw(Counter)], # too slow, not inlined, nytprof gives it about 60% of runtime =P
            is  => "ro",
            writer => "_set_${pool}_$counter",
            default => sub { 0 },
            #handles => {
            #   "_inc_${pool}_$counter"   => "inc",
            #   "_dec_${pool}_$counter"   => "dec",
            #   "_reset_${pool}_$counter" => "reset",
            #},
        );
    }
}

sub _reset_mru_size {
    my $self = shift;
    $self->_set_mru_size(0);
}

sub _inc_mru_size {
    my $self = shift;
    $self->_set_mru_size( $self->_mru_size + 1 );
}

sub _dec_mru_size {
    my $self = shift;
    $self->_set_mru_size( $self->_mru_size - 1 );
}

sub _reset_mfu_size {
    my $self = shift;
    $self->_set_mfu_size(0);
}

sub _inc_mfu_size {
    my $self = shift;
    $self->_set_mfu_size( $self->_mfu_size + 1 );
}

sub _dec_mfu_size {
    my $self = shift;
    $self->_set_mfu_size( $self->_mfu_size - 1 );
}

sub _reset_mru_history_size {
    my $self = shift;
    $self->_set_mru_history_size(0);
}

sub _inc_mru_history_size {
    my $self = shift;
    $self->_set_mru_history_size( $self->_mru_history_size + 1 );
}

sub _dec_mru_history_size {
    my $self = shift;
    $self->_set_mru_history_size( $self->_mru_history_size - 1 );
}

sub _reset_mfu_history_size {
    my $self = shift;
    $self->_set_mfu_history_size(0);
}

sub _inc_mfu_history_size {
    my $self = shift;
    $self->_set_mfu_history_size( $self->_mfu_history_size + 1 );
}

sub _dec_mfu_history_size {
    my $self = shift;
    $self->_set_mfu_history_size( $self->_mfu_history_size - 1 );
}


has _mru_target_size => ( # p
    is => "ro",
    writer => "_set_mru_target_size",
    default => 0,
);

sub hit {
    my ( $self, @keys ) = @_;

    $self->_hit( [ grep { defined } $self->_index_get(@keys) ] );

    return;
}

sub peek {
    my ( $self, @keys ) = @_;

    my @ret;

    my @entries = $self->_index_get(@keys);

    return ( @keys == 1 ? ($entries[0] && $entries[0][2]) : map { $_ && $_->[2] } @entries );
}

sub get {
    my ( $self, @keys ) = @_;

    my @ret;

    my @entries = $self->_index_get(@keys);

    $self->_hit( [ grep { defined } @entries ] );

    return ( @keys == 1 ? ($entries[0] && $entries[0][2]) : map { $_ && $_->[2] } @entries );
}

sub _circular_splice {
    my ( $self, $list, $node ) = @_;

    my $tail = $self->$list or confess;
    my $next = $self->_next($node);

    # splice out of mru
    if ( $next == $node ) {
        $self->$list(undef);
    } else {
        $self->_set_next( $tail, $next );
    }

    $self->_set_next($node, undef);

    $self->${\"_dec${list}_size"};
}

sub _circular_push {
    my ( $self, $list, $new_tail ) = @_;

    if ( my $tail = $self->$list ) {
        my $head = $self->_next($tail);

        # splice $e in
        $self->_set_next($tail, $new_tail);
        $self->_set_next($new_tail, $head);
    } else {
        $self->_set_next($new_tail, $new_tail);
    }

    $self->${\"_inc${list}_size"};

    # $hand++
    $self->$list($new_tail);
}

sub _hit {
    my ( $self, $e ) = @_;

    foreach my $entry ( @$e ) {
        if ( exists $entry->[2] ) {
            # if it's in T1 ∪ T2, the value is set
            $entry->[0] ||= 1;
        #} else {
            # cache history hit
            # has no effect until 'set'
        }
    }
}

sub set {
    my ( $self, $key, $value ) = @_;

    my $e = $self->_index_get($key);

    if ( $e and exists $e->[2] ) {
        # just a value update
        $self->_hit([$e]);
        return $e->[2] = $value;
    }

    # the live cache entries are full, we need to expire something
    if ( $self->_mru_size + $self->_mfu_size == $self->size ) {
        $self->_expire();

        # if the entry wasn't in history we may need to free up something from
        # there too, to make room for whatever just expired
        if ( !$e ) {
            if ( $self->_mru_history_too_big ) {
                $self->_index_delete( $self->_mru_history_pop );
                $self->_dec_mru_history_size;
            } elsif ( $self->_mfu_history_too_big ) {
                $self->_index_delete($self->_mfu_history_pop);
                $self->_dec_mfu_history_size;
            }
        }
    }

    if ( !$e ) {
        # cache directory miss
        # this means the key is neither cached nor recently expired
        $self->_insert_new_entry( $key, $value );
    } else {
        # cache directory hit

        # restore from the appropriate history list
        if ( $e->[0] & MFU_HISTORY_BIT ) {
            $e->[0] &= ~MFU_HISTORY_BIT;

            $self->_decrease_mru_target_size();

            $self->_mfu_history_splice($e);
            $self->_dec_mfu_history_size;

            $self->_restore_from_mfu_history($e);
        } else {
            $self->_increase_mru_target_size();

            $self->_mru_history_splice($e);
            $self->_dec_mru_history_size;

            $self->_restore_from_mru_history($e);

        }

        # the entry has a key and flags but no value
        # it's already indexed currectly, so no need for _index_set
        $e->[2] = $value;
    }

    return $value;
}

sub _insert_new_entry {
    my ( $self, $key, $value ) = @_;

    my $e = [ 0, $key, $value ]; # 0 means no special bits are set

    # simply insert to the MRU pool
    $self->_circular_push( _mru => $e );
    $self->_index_set( $key => $e );
}

sub clear {
    my $self = shift;

    $self->_index_clear;
    $self->_mfu_history_clear;
    $self->_mru_history_clear;
    $self->_reset_mru_history_size;
    $self->_reset_mfu_history_size;
    $self->_reset_mfu_size;
    $self->_reset_mru_size;
    $self->_circular_clear("_mfu");
    $self->_circular_clear("_mru");

    $self->_clear_additional;

    return;
}

sub _circular_clear {
    my ( $self, $list ) = @_;

    my $cur = $self->$list;
    $self->$list(undef);

    while ( $cur ) {
        my $next = $cur->[3];
        @$cur = ();
        $cur = $next;
    }
}

sub DEMOLISH { shift->clear }

sub remove { die "FIXME" }

# ex: set sw=4 et:

__PACKAGE__

__END__
