package Cache::Ref::CLOCK;
use Moose;

use namespace::autoclean;

extends qw(Cache::Ref);

with qw(Cache::Ref::CLOCK::Base);

has k => (
    isa => "Int",
    is  => "ro",
    default => 1,
);

sub _hit {
    my ( $self, $e ) = @_;

    my $k = 0+$self->k; # moose stingifies default
    $_->[0] = $k for @$e;
}

__PACKAGE__->meta->make_immutable;

# ex: set sw=4 et:

__PACKAGE__

__END__

