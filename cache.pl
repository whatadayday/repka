#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use REST::Client;
use JSON::XS;
use CHI;
use Dancer2;
use POSIX;
use File::stat;

use Data::Dumper;

# Consts
my $API_KEY = '23567b218376f79d9415';

my $CACHE_PATH = '/tmp/cache';
my $CACHE_TERM = '5 minutes';

# Initializing objects
my $client = REST::Client->new();
$client->setHost('http://interview.agileengine.com');

my $json = JSON::XS->new->allow_nonref->convert_blessed(1);

# create cache
if( ! -w $CACHE_PATH) {
    cacher_log( $CACHE_PATH . ' can\'t be open to write...');
    exit 1;
}
my $cacheImg = CHI->new( driver   => 'File', root_dir => $CACHE_PATH);

# unset flag
$cacheImg->set('__updating', 0);

# auth
my $tokenKey = get_token();

# Server handlers 
get '/images/:id/' => sub {
    my $id = route_parameters->{'id'};
    
    if ( ! $cacheImg->get_object( $id) || $cacheImg->exists_and_is_expired( $id)) {
        cacher_log( $id . ' not found or cache is expired');
        cacher_log( $id . ' fetching from server');
        my $imgData = fetch_and_cache_img( $id);

        # meta could be status => 'not found'
        return $json->encode( $imgData->{meta});
    }
    
    cacher_log( $id . ' exists in a cache and not expired');
    return $json->encode( $cacheImg->get($id)->{meta});
};
 
get '/search/:attr/:val/' => sub {
    my $attr = route_parameters->{'attr'};
    my $val = route_parameters->{'val'};

    if ( $cacheImg->exists_and_is_expired('META')) {
        cacher_log('Meta search cache is expired');
        while( $cacheImg->exists_and_is_expired('META') && !loadData2Cache()) {
            sleep 1;
        }
    }
    
    my $metaRef = $cacheImg->get('META');
    my @res;
    foreach my $meta (@$metaRef) {
        unless ( defined $meta->{$attr}) {
            return "Unknown meta field $attr";
        }
        
        # non case-sensitive comparison 
        if (lc $meta->{$attr} eq lc $val ) {
            push @res, $meta; 
        }
    }

    return $json->encode( \@res);
};

# Body

# update cache
loadData2Cache();

# starting server
start;

# /Body

# aim: Updating cache
# params: no
# Cache struct: id1 => { meta => { author => ... , camera => ... , }, binary => ..., }, id2 => {...},
# return:
# 1 success
# 0 cache updating by another process
sub loadData2Cache {
    my $respImg;
    my @metaData;
    
    # already updating
    if ($cacheImg->get('__updating')) {
        cacher_log('Already updating');
        return 0;
    }
    
    # set flag
    $cacheImg->set('__updating', 1);
    
    cacher_log('Caching started...');
    
    my $page = 0;
    my $has_more = 1;

    while ($has_more) {
        $client->GET("/images?page=$page", {Authorization => 'Bearer '. $tokenKey});
        $respImg = $json->decode( $client->responseContent() );

        unless (check_auth($respImg)) {
            $tokenKey = get_token();
            next;
        }

        unless (@{ $respImg->{pictures}}) {
            last;
        }

        foreach my $pic (@{ $respImg->{pictures}}) {
            my $imgData; 
            my $id = $pic->{id};

            if ( ! $cacheImg->get_object($id) || $cacheImg->exists_and_is_expired($id)) {
                $imgData = fetch_and_cache_img( $pic->{id});
            }
            else {
                $imgData = $cacheImg->get($id);
            }
            
            push @metaData, $imgData->{meta};
        }

        $page++;
        $has_more = $respImg->{hasMore};
    }
    
    # put meta data to cash
    $cacheImg->set( 'META', \@metaData, $CACHE_TERM );

    # unset flag
    $cacheImg->set('__updating', 0);

    cacher_log( scalar @metaData. ' images cached...');

    return 1;
}

# aim: fetch img data from server and cache it
# it not found returning {status => 'not found'}
# params: id
# return: ref to hash {
#   meta   => ,
#   binary => ,
# }
sub fetch_and_cache_img {
    my $id = shift;

    my $imgData = {
        meta   => fetch_img_meta($id),
    };
    
    if ($imgData->{meta}->{cropped_picture}) {
        $imgData->{binary} = fetch_img_binary( $imgData->{meta}->{cropped_picture});
    }
    else {
        cacher_log( $id . ' image not found');
    }
    
    # cache if img exists
    if ( $imgData->{meta}->{id}) {
        $cacheImg->set( $id, $imgData, $CACHE_TERM);
    }
    
    return $imgData;
}

# aim: fetch img meta data from server
# params: id
# return: ref to hash
sub fetch_img_meta {
    my $id = shift;
    
    while (1) {
        $client->GET('/images/'. $id, {Authorization => 'Bearer '. $tokenKey});
        my $respMeta = $json->decode( $client->responseContent() );
    
        unless (check_auth($respMeta)) {
            $tokenKey = get_token();
            next;
        }
        
        return $respMeta;
    }
}

# aim: fetch img binary data from server
# params: id
# return: scalar
sub fetch_img_binary {
    my $picpath = shift;
    
    $picpath =~ s/http:\/\/.+?\///;
    
    # fecth image binary
    $client->GET( $picpath, { 'Content-type' => 'image'});
    
    return $client->responseContent();
}

# aim: check if response is authorized
# return: 0, 1
sub check_auth {
    my $resp  = shift;
  
    if ( !$resp || ( $resp->{'status'} && $resp->{'status'} eq 'Unauthorized') ) {
        return 0;
    }
    
    return 1;
}

# aim: get token
# return: token
sub get_token {
    $client->POST('/auth/', '{ "apiKey": "'. $API_KEY . '" }',
        { 'Content-type' => 'application/json'});    
  
    my $resp = $client->responseContent();
    
    return $json->decode($resp)->{token} || undef;
}

# aim: logging system message
sub cacher_log {
    my $msg = shift;
    
    my $datestr = strftime("%a %b %e %H:%M:%S %Y", gmtime);
    print $datestr. ': ' . $msg . "\n";
}

1;
