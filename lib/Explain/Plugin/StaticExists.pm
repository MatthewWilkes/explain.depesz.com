package Explain::Plugin::StaticExists;
use Mojo::Base qw( Mojolicious::Plugin );

use File::Spec;

sub register {
    my ( $self, $app ) = @_;

    $app->helper(
        'static_exists' => sub {
            my ( $self, $file ) = @_;

            for my $path ( @{ $self->app->static->paths } ) {
                return 1 if -e File::Spec->catfile( $path, split('/', $file ) );
            }

            return;
        }
    );
}

1;
