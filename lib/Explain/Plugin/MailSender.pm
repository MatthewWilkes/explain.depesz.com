package Explain::Plugin::MailSender;

use Mojo::Base 'Mojolicious::Plugin';
use English -no_match_vars;
use Email::Sender::Simple qw(sendmail);
use Email::Simple;

__PACKAGE__->attr( config => sub { {} } );

sub register {
    my ( $self, $app, $config ) = @_;

    # save settings
    $self->config( $config );

    # register helper
    $app->helper(
        send_mail => sub {
            my ( $controller, $mail ) = @_;

            eval {
                my $email = Email::Simple->create(
                    header => [
                        To      => $self->config->{ 'to' },
                        From    => $self->config->{ 'from' },
                        Subject => $self->config->{ 'subject' },
                    ],
                    body => $mail->{ 'msg' },
                );

                # log debug message
                $controller->app->log->debug( sprintf "Sending mail:\n%s", $controller->dumper( $email ) );

                sendmail( $email );
            };

            if ( $EVAL_ERROR ) {
                my $message = "Mail send failed, reason: " . $EVAL_ERROR;
                $controller->app->log->fatal( $message );
                die $message;
            }

            return 1;
        }
    );
}

1;
