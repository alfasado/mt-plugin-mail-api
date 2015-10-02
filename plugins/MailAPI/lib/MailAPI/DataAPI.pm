package MailAPI::DataAPI;

use strict;
use warnings;
use Data::Dumper;

use MT::DataAPI::Endpoint::Common;
use MT::DataAPI::Format::JSON;

sub _send_email {
    my ( $app, $endpoint ) = @_;
    my $user = $app->user;
    my ( $blog ) = context_objects( @_ ) or return;
    if (! $app->user || $app->user->is_anonymous ) {
        return $app->print_error( 'Unauthorized', 401 );
    } else {
        if (! $app->user->is_superuser ) {
            my $perm = $user->permissions( $blog->id )->can_administer;
            if (! $perm ) {
                $perm = $user->permissions( $blog->id )->can_api_send_email;
            }
            if (! $perm ) {
                return $app->print_error( 'Permission denied', 403 );
            }
        }
    }
    # email={"To":"webmaster@alfasado.jp","Subject":"Mail Subject","Body":{"template_id":119,"build":"true"}}
    my $json = $app->param( 'email' );
    $json = MT::DataAPI::Format::JSON::unserialize( $json );
    my $args = { blog => $blog, author => $app->user };
    my $subject = $json->{ Subject }; # optional
    if ( $subject ) {
        if ( ref $subject eq 'HASH' ) {
            $subject = _build_field( $app, $args, $subject );
            if ( ( ref $subject ) eq 'ARRAY' ) {
                return $app->print_error( @$subject[0], @$subject[1] );
            }
        }
        delete( $json->{ Subject } );
    }
    my $to = $json->{ To }; # optional
    if ( $to ) {
        if ( ref $to eq 'HASH' ) {
            $to = _build_field( $app, $args, $to );
            if ( ( ref $to ) eq 'ARRAY' ) {
                return $app->print_error( @$to[0], @$to[1] );
            }
        }
        delete( $json->{ To } );
    }
    my $from = $json->{ From }; # optional
    if ( $from ) {
        if ( ref $from eq 'HASH' ) {
            $from = _build_field( $app, $args, $from );
        }
        delete( $json->{ from } );
    }
    my $head = $json->{ Head };
    if ( $head && ( ( ref $head ) eq 'HASH' ) ) {
        for my $key ( keys %$head ) {
            my $value = $head->{ $key };
            if ( ref $value eq 'HASH' ) {
                $value = _build_field( $app, $args, $value );
                if ( ( ref $value ) eq 'ARRAY' ) {
                    return $app->print_error( @$value[0], @$value[1] );
                }
            }
            $json->{ Head }->{ $key } = $value;
        }
    }
    if ( $subject ) {
        $head->{ Subject } = $subject;
    }
    if ( $to ) {
        $head->{ To } = $to;
    }
    if ( $from ) {
        $head->{ From } = $from;
    } else {
        $head->{ From } = MT->config( 'EmailAddressMain' );
    }
    my $body = $json->{ Body }; # required
    if ( ref $body eq 'HASH' ) {
        $body = _build_field( $app, $args, $body );
        if ( ( ref $body ) eq 'ARRAY' ) {
            return $app->print_error( @$body[0], @$body[1] );
        }
    }
    if ( (! $head->{ To } ) || (! $head->{ From } ) ) {
        return $app->print_error( 'Required Mail header does not specified', 500 );
    }
    $json->{ Head } = $head;
    $json->{ Body } = $body;
    require MT::Mail;
    MT::Mail->send( $head, $body ) or die MT::Mail->errstr;
    return $json;
}

sub _build_field {
    my ( $app, $args, $hash ) = @_;
    my $blog = $args->{ blog };
    my $text;
    if ( my $template_id = $hash->{ template_id } ) {
        my $template = MT->model( 'template' )->load( { id => $template_id, blog_id => $blog->id } );
        if (! $template ) {
            return [ "Template [Id:${template_id}] was not found", 404 ];
        }
        $text = $template->text;
    }
    if ( $hash->{ build } && ( $hash->{ build } eq 'true' ) ) {
        $text = _build( $app, $args, $text );
    }
    return $text;
}

sub _build {
    my ( $app, $args, $tmpl ) = @_;
    require MT::Builder;
    require MT::Template::Context;
    my $ctx = MT::Template::Context->new;
    my $blog = $args->{ blog };
    my $author = $args->{ author };
    $ctx->stash( 'blog', $blog );
    $ctx->stash( 'blog_id', $blog->id );
    $ctx->stash( 'local_blog_id', $blog->id );
    $ctx->stash( 'author', $author );
    $ctx->{ __stash }->{ vars }->{ magic_token } = $app->current_magic if $app->user;
    my $build = MT::Builder->new;
    my $tokens = $build->compile( $ctx, $tmpl );
    return $build->build( $ctx, $tokens );
}

1;