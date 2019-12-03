package Explain::Controller;

use Mojo::Base 'Mojolicious::Controller';

use English -no_match_vars;

use Pg::Explain;
use Encode;
use Email::Valid;
use Config;
use Digest::MD5 qw( md5_hex );

sub logout {
    my $self = shift;
    delete $self->session->{ 'user' };
    delete $self->session->{ 'admin' };
    $self->redirect_to( 'new-explain' );
}

sub user_history {
    my $self = shift;
    $self->redirect_to( 'history' ) unless $self->session->{ 'user' };

    my @args = ( $self->session->{ 'user' } );
    if (   ( $self->param( 'direction' ) )
        && ( $self->param( 'direction' ) =~ m{\A(?:before|after)\z} )
        && ( $self->param( 'key' ) ) )
    {
        push @args, $self->param( 'direction' ) eq 'before' ? 'DESC' : 'ASC';
        push @args, $self->param( 'key' );
    }
    my $data = $self->database->get_user_history( @args );
    $self->stash->{ 'plans' } = $data;
    return $self->render();
}

sub user {
    my $self = shift;

    my $old  = $self->req->param( 'old-pw' );
    my $new  = $self->req->param( 'new-pw' );
    my $new2 = $self->req->param( 'new-pw2' );

    return $self->render unless defined $old;

    if (   ( !defined $new )
        || ( !defined $new2 )
        || ( $new ne $new2 ) )
    {
        $self->stash->{ 'message' } = 'You have to provide two identical copies of new password!';
        return;
    }
    my $status = $self->database->user_change_password( $self->session->{ 'user' }, $old, $new );
    if ( $status ) {
        $self->flash( 'message' => 'Password changed.' );
        $self->redirect_to( 'new-explain' );
    }
    $self->stash->{ 'message' } = 'Changing the password failed.';
}

sub plan_change {
    my $self = shift;
    unless ( $self->session->{ 'user' } ) {
        $self->app->log->error( 'User tried to access plan change without being logged!' );
        $self->redirect_to( 'new-explain' );
    }
    $self->redirect_to( 'new-explain' ) unless $self->req->param( 'return' );

    my $plan = $self->database->get_plan_data( $self->param( 'id' ) );
    if (   ( !defined $plan->{ 'added_by' } )
        || ( $plan->{ 'added_by' } ne $self->session->{ 'user' } ) )
    {
        $self->app->log->error( 'User tried to access plan change for plan [' . $plan->{ 'id' } . '] of another user: ' . $self->session->{ 'user' } );
        $self->redirect_to( 'logout' );
    }

    # All looks fine. Current plan data are in $plan.
    if (   ( $self->req->param( 'delete' ) )
        && ( $self->req->param( 'delete' ) eq 'yes' ) )
    {
        $self->database->delete_plan( $plan->{ 'id' }, $plan->{ 'delete_key' } );
        return $self->redirect_to( $self->req->param( 'return' ) );
    }

    my %changes = ();
    if ( $plan->{ 'title' } ne ( $self->req->param( 'title' ) // '' ) ) {
        $changes{ 'title' } = ( $self->req->param( 'title' ) // '' );
    }
    if (   ( $plan->{ 'is_public' } )
        && ( !$self->req->param( 'is_public' ) ) )
    {
        $changes{ 'is_public' } = 0;
    }
    elsif (( !$plan->{ 'is_public' } )
        && ( $self->req->param( 'is_public' ) ) )
    {
        $changes{ 'is_public' } = 1;
    }

    if (   ( !$plan->{ 'is_anonymized' } )
        && ( $self->req->param( 'is_anonymized' ) ) )
    {
        my $explain = Pg::Explain->new( source => $plan->{ 'plan' } );
        $explain->anonymize();
        $changes{ 'plan' }          = $explain->as_text();
        $changes{ 'is_anonymized' } = 1;
    }

    return $self->redirect_to( $self->req->param( 'return' ) ) if 0 == scalar keys %changes;

    $self->database->update_plan( $plan->{ 'id' }, \%changes );

    return $self->redirect_to( $self->req->param( 'return' ) );
}

sub login {
    my $self = shift;

    # If there is no username - there is nothing to do
    my $username = $self->req->param( 'username' );
    return $self->render unless defined $username;

    if ( 30 < length( $username ) ) {
        $self->stash->{ 'message' } = 'Username cannot be longer than 30 characters. Really?!';
        return;
    }

    my $password  = $self->req->param( 'password' );
    my $password2 = $self->req->param( 'password2' );

    if ( ( !defined $password ) || ( '' eq $password ) ) {
        $self->stash->{ 'message' } = 'There has to be some password!';
        return;
    }

    # Registration
    if ( $self->req->param( 'is_registration' ) ) {
        if (   ( !defined $password2 )
            || ( $password2 ne $password ) )
        {
            $self->stash->{ 'message' } = 'You have to repeat password correctly!';
            return;
        }

        my $status = $self->database->user_register( $username, $password );
        if ( $status ) {
            $self->flash( 'message' => 'User registered.' );
            $self->session( 'user' => $username );
            $self->redirect_to( 'new-explain' );
        }
        $self->stash->{ 'message' } = 'Registration failed.';
        return;
    }

    if ( my $user = $self->database->user_login( $username, $password ) ) {
        $self->flash( 'message' => 'User logged in.' );
        $self->session( 'user'  => $username );
        $self->session( 'admin' => $user->{ 'admin' } );
        $self->redirect_to( 'new-explain' );
    }
    $self->stash->{ 'message' } = 'Bad username or password.';
    return;
}

sub new_optimization {
    my $self = shift;

    my $original_plan_id = $self->req->param( 'original' ) // '';

    return $self->redirect_to( 'new-explain' ) unless $original_plan_id =~ m{\A[a-zA-Z0-9]+\z};

    my ( $original_plan, $original_title ) = $self->database->get_plan( $original_plan_id );

    return $self->redirect_to( 'new-explain', status => 404 ) unless $original_plan;

    $self->stash->{ 'optimization' }     = 1;
    $self->stash->{ 'original_plan_id' } = $original_plan_id;
    $self->stash->{ 'original_title' }   = $original_title;

    return $self->render( 'controller/index' );
}

sub index {
    my $self = shift;

    # plan
    my $plan = $self->req->param( 'plan' );

    # nothing to do...
    return $self->render unless $plan;

    # request entity too large
    return $self->render( message => 'Your plan is too long.', status => 413 )
        if 10_000_000 < length $plan;

    # Get id of parent plan
    my $parent_id = $self->req->param( 'optimization_for' );
    if ( defined $parent_id ) {
        $parent_id = undef unless $self->database->plan_exists( $parent_id );
    }

    # public
    my $is_public = $self->req->param( 'is_public' ) ? 1 : 0;

    # anonymization
    my $is_anon = $self->req->param( 'is_anon' ) ? 1 : 0;

    # plan title
    my $title = $self->req->param( 'title' );
    $title = '' unless defined $title;
    $title = '' if 'Optional title' eq $title;

    # try
    eval {

        # make "explain"
        my $explain = Pg::Explain->new( source => $plan );

        # something goes wrong...
        die q|Can't create explain! Explain "top_node" is undef!|
            unless defined $explain->top_node;

        # Anonymize plan, when requested.
        if ( $is_anon ) {
            $explain->anonymize();
            $plan = $explain->as_text();
        }

    };

    # catch
    if ( $EVAL_ERROR ) {

        # log message
        $self->app->log->info( $EVAL_ERROR );

        # leave...
        return $self->render( message => q|Failed to parse your plan| );
    }

    # save to database
    my ( $id, $delete_key ) = $self->database->save_with_random_name( $title, $plan, $is_public, $is_anon, $self->session->{ 'user' }, $parent_id, );

    # redirect to /show/:id
    $self->flash( delete_key => $delete_key );
    return $self->redirect_to( 'show', id => $id );
}

sub delete {
    my $self = shift;

    # value of "/:id" param
    my $id = defined $self->stash->{ id } ? $self->stash->{ id } : '';

    # value of "/:key" param
    my $key = defined $self->stash->{ key } ? $self->stash->{ key } : '';

    # missing or invalid
    return $self->redirect_to( 'new-explain' ) unless $id =~ m{\A[a-zA-Z0-9]+\z};
    return $self->redirect_to( 'new-explain' ) unless $key =~ m{\A[a-zA-Z0-9]+\z};

    # delete plan in database
    my $delete_worked = $self->database->delete_plan( $id, $key );

    # not found in database
    return $self->redirect_to( 'new-explain', status => 404 ) unless $delete_worked;

    $self->flash( message => sprintf( 'Plan %s deleted.', $id ) );
    return $self->redirect_to( 'new-explain' );
}

sub show {
    my $self = shift;

    # value of "/:id" param
    my $id     = defined $self->stash->{ id } ? $self->stash->{ id } : '';

    # missing or invalid
    return $self->redirect_to( 'new-explain' ) unless $id =~ m{\A[a-zA-Z0-9]+\z};

    # get plan source from database
    my ( $plan, $title ) = $self->database->get_plan( $id );

    # not found in database
    return $self->redirect_to( 'new-explain', status => 404 ) unless $plan;

    # make explanation
    my $explain = eval { Pg::Explain->new( source => $plan ); };

    # plans are validated before save, so this should never happen
    if ( $EVAL_ERROR ) {
        $self->app->log->error( $EVAL_ERROR );
        return $self->redirect_to( 'new-explain' );
    }

    # validate explain
    eval { $explain->top_node; };

    # as above, should never happen
    if ( $EVAL_ERROR ) {
        $self->app->log->error( $EVAL_ERROR );
        return $self->redirect_to( 'new-explain' );
    }

    # Get stats from plan
    my $stats    = { 'tables' => {} };
    my @elements = ( $explain->top_node );
    while ( my $e = shift @elements ) {
        push @elements, values %{ $e->ctes } if $e->ctes;
        push @elements, @{ $e->sub_nodes }   if $e->sub_nodes;
        push @elements, @{ $e->initplans }   if $e->initplans;
        push @elements, @{ $e->subplans }    if $e->subplans;

        $stats->{ 'nodes' }->{ $e->type }->{ 'count' }++;
        $stats->{ 'nodes' }->{ $e->type }->{ 'time' } += $e->total_exclusive_time if $e->total_exclusive_time;

        next unless $e->scan_on;
        next unless $e->scan_on->{ 'table_name' };
        $stats->{ 'tables' }->{ $e->scan_on->{ 'table_name' } } ||= {};
        my $S = $stats->{ 'tables' }->{ $e->scan_on->{ 'table_name' } };
        $S->{ $e->{ 'type' } }->{ 'count' }++;
        $S->{ ':total' }->{ 'count' }++;
        if ( defined( my $t = $e->total_exclusive_time ) ) {
            $S->{ $e->type }->{ 'time' } += $t;
            $S->{ ':total' }->{ 'time' } += $t;
        }
    }

    # put explain and title to stash
    $self->stash->{ explain } = $explain;
    $self->stash->{ title }   = $title;
    $self->stash->{ stats }   = $stats;

    # Fetch path of optimizations
    $self->stash->{ optimization_path } = $self->database->get_optimization_path( $id );
    $self->stash->{ suboptimizations }  = $self->database->get_optimizations_for( $id );

    # render will be called automatically

    return $self->render( 'controller/iframe' ) if 'iframe' eq $self->match->endpoint->name;

    return;
}

sub history {
    my $self = shift;

    # date
    my $date = $self->param( 'date' );

    if ( ( $date ) && ( $date lt '2008-12-01' ) ) {
        return $self->redirect_to( '/' );
    }

    # get result set from database
    my $rs = $self->database->get_public_list_paged( $date );

    # put result set to stash
    $self->stash( rs => $rs );

    return;
}

sub contact_post {
    my $self = shift;

    return $self->redirect_to( 'contact' ) unless $self->req->param( 'message' );

    my $session_nonce = $self->session->{ 'nonce' };
    my $param_nonce   = $self->req->param( 'nonce' );
    my $prefix        = $self->req->param( 'nonceprefix' );

    if (   ( !defined $session_nonce )
        || ( !defined $param_nonce )
        || ( $session_nonce ne $param_nonce ) )
    {
        $self->flash( error => "Please don't hack me" );
        return $self->redirect_to( 'contact' );
    }
    if (   ( !defined $prefix )
        || ( $prefix eq '' ) )
    {
        $self->flash( error => "Sorry, due to contact spam, you need JavaScript to contact me." );
        return $self->redirect_to( 'contact' );
    }

    my ( $level, $nonce ) = split( /:/, $session_nonce );
    my $md5_prefix = substr( md5_hex( $prefix . $nonce ), 0, $level );
    $md5_prefix =~ s/0//g;
    if ( $md5_prefix ne '' ) {
        $self->flash( error => "Please don't hack me" );
        return $self->redirect_to( 'contact' );
    }

    # invalid email address
    return $self->render( error => 'Invalid email address' )
        unless Email::Valid->address( $self->req->param( 'email' ) || '' );

    my $client_ip = $self->tx->remote_address;
    if ( my $forward = $self->req->headers->header( 'x-forwarded-for' ) ) {
        $client_ip .= sprintf " (from: %s)", $forward;
    }

    my @mail_template_lines = ();
    push @mail_template_lines, 'Message from: %s <%s>';
    push @mail_template_lines, 'Posted  from: %s with %s';
    push @mail_template_lines, 'Prefix: %s';
    push @mail_template_lines, '***********************************************';
    push @mail_template_lines, '%s';
    my $mail_template = "\n" . join( "\n", @mail_template_lines ) . "\n\n";

    # send
    $self->send_mail(
        {
            msg => sprintf(
                $mail_template,
                $self->req->param( 'name' ) || '',
                $self->req->param( 'email' ),
                $client_ip,
                $self->req->headers->user_agent,
                $prefix,
                $self->req->param( 'message' )
            )
        }
    );

    # mail sent message
    $self->flash( message => 'Mail sent' );

    # get after post
    $self->redirect_to( 'contact' );
}

sub contact {
    my $self = shift;

    my @chars = ( "a" .. "z", "A" .. "Z", "0" .. "9" );
    my $level = 2;
    my $nonce = $level . ':' . join( '', map { $chars[ rand @chars ] } 1 .. 20 );
    $self->stash->{ 'nonce' }   = $nonce;
    $self->session->{ 'nonce' } = $nonce;
    return;
}

sub info {
    my $self = shift;
    $self->redirect_to( 'new-explain' ) unless $self->session->{ 'user' };
    $self->redirect_to( 'new-explain' ) unless $self->session->{ 'admin' };

    my @versions = ();
    for my $module ( sort keys %INC ) {
        next if $module =~ m{^\.?/};
        $module =~ s/\.pm$//;
        $module =~ s#/#::#g;
        push @versions,
            {
            'module'  => $module,
            'version' => $module->VERSION,
            };
    }
    $self->stash( 'modules' => \@versions );
    $self->stash(
        'perl' => {
            'version' => $PERL_VERSION,
            'binary'  => $Config{ 'perlpath' } . $Config{ '_exe' },
        }
    );

}

sub status {
    my $self = shift;
    if ( $self->database->ping() ) {
        $self->render( 'text' => 'OK', status => 200 );
    }
    else {
        $self->render( 'text' => 'DB FAILED', status => 500 );
    }
}

sub help {

    # direct to template
    return ( shift )->render;
}

1;
