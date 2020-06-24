#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use REST::Client;
use JSON::XS;
use CHI;
use Dancer2;
use POSIX qw(strftime);

use Data::Dumper;

# Consts
my $API_KEY = '23567b218376f79d9415';

my $CACHE_PATH = '/Cache';
my $CACHE_TERM = '5 minutes';

# Initializing objects
my $client = REST::Client->new();
$client->setHost('http://interview.agileengine.com');

my $json = JSON::XS->new->allow_nonref->convert_blessed(1);

# create cache
my $cacheImg = CHI->new(
    driver   => 'File', 
    root_dir => $CACHE_PATH,
);

# auth
my $tokenKey = get_token();

# Server handlers 
get '/images/:id/' => sub {
    my $id = route_parameters->{'id'};

    if ( $cacheImg->exists_and_is_expired('META') || $cacheImg->exists_and_is_expired( $id)) {
        
        cacher_log('Cache is expired');
        
        # Forking to not wait cache update
        my $pid = fork();
        die "Failed to fork: $!" unless defined $pid;
        
        # Fetch image directly from server
        if ( $pid) {
            while (1) {
                $client->GET('/images/'. $id, {Authorization => 'Bearer '. $tokenKey});
                my $respMeta = $json->decode( $client->responseContent() );
            
                unless (check_auth($respMeta)) {
                    $tokenKey = get_token();
                    next;
                }

                # update cach via GET to no wait the response
                # $clientLocal->POST('/updatecache/');
                return $json->encode( $respMeta);
            }
        }
        
        # Updating cache
        return loadData2Cache();
    }

    return $json->encode( $cacheImg->get('META')->{$id});
};
 
get '/search/:attr/:val/' => sub {
    my $attr = route_parameters->{'attr'};
    my $val = route_parameters->{'val'};

    if ( $cacheImg->exists_and_is_expired('META')) {
        loadData2Cache();
    }
    
    my $metaRef = $cacheImg->get('META');
    my @res;
    foreach my $id (keys %$metaRef) {
        unless ( defined $metaRef->{$id}->{$attr}) {
            return "Unknown meta field $attr";
        }
        
        if ( $metaRef->{$id}->{$attr} eq $val ) {
            push @res, $metaRef->{$id}; 
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
# Cache struct:
# id2 => binary_image
# id2 => ...,
# META => { id1 => { author => ... , camera => ... }, id2 => { ... } }
# return: 1
sub loadData2Cache {
    my $respImg;
    my @metaDataArr;
    
    # already updating
    if ($cacheImg->get('__updating')) {
        return 1;
    }
    
    # set flag
    $cacheImg->set('__updating', 1);
    
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
            # remove domain name
            $pic->{cropped_picture} =~ s/http:\/\/.+?\///;
            
            $client->GET( $pic->{cropped_picture}, { 'Content-type' => 'image'});
            $cacheImg->set( $pic->{id},  $client->responseContent(), $CACHE_TERM );

            my $respMeta;
            while (1) {
                $client->GET('/images/'. $pic->{id}, {Authorization => 'Bearer '. $tokenKey});
                $respMeta = $json->decode( $client->responseContent() );
            
                unless (check_auth($respMeta)) {
                    $tokenKey = get_token();
                    next;
                }
                last;
            }

            push @metaDataArr, $respMeta;
        }

        $page++;
        $has_more = $respImg->{hasMore};
    }
    
    # put meta data to cash
    my %metaDataHash = map { $_->{id} => $_ } @metaDataArr;
    $cacheImg->set( 'META', \%metaDataHash, $CACHE_TERM );

    # unset flag
    $cacheImg->set('__updating', 0);

    cacher_log( scalar @metaDataArr. ' images cached...');

    return 1;
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
    print $datestr. ' : ' . $msg . "\n";
}

1;
