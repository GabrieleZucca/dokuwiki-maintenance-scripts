#!/usr/bin/env perl

# Gabriele Zucca
# Ultima modifica: 18/07/2026

use feature 'say';
use strict;
use warnings;
use utf8;
use open qw/:std :utf8/;

use List::Util qw/shuffle/;
use Term::ReadPassword;
use Getopt::Long;
use LWP::UserAgent;
use HTTP::Request;
use JSON::PP qw/encode_json decode_json/;
use MIME::Base64 qw/encode_base64/;

# Parametri di default
my $n         = 5;
my $namespace = '';
my $protocol  = 'http';
my $host      = 'localhost';
my $basedir   = '/wiki/';

# Prova a leggere username e pw tra le variabili di ambiente. Se sono
# specificate nei parametri dello script questi valori verranno sovrascritti
my $user     = $ENV{DOKUWIKI_XMLRPC_USER};
my $password = $ENV{DOKUWIKI_XMLRPC_PASSWORD};

GetOptions(
    "n=i"         => \$n,
    "user=s"      => \$user,
    "password=s"  => \$password,
    "namespace=s" => \$namespace,
    "host=s"      => \$host,
    "protocol=s"  => \$protocol,
    "basedir=s"   => \$basedir,
);

die 'Utente non definito.' unless defined $user;

unless ( defined $password ) {
    die "Password non fornita e nessun terminale disponibile per chiederla "
      . "in modo interattivo.\n"
      unless -t STDIN;

    do {
        $password = read_password("Password per l'utente $user: ");
    } until ( defined $password && $password =~ /\S/ );
}

die "Protocollo non valido: $protocol!"
  unless $protocol =~ /^http[s]{0,1}$/i;

$protocol = lc $protocol;

my $jsonrpc_url = "$protocol://${host}${basedir}lib/exe/jsonrpc.php";

my $ua          = LWP::UserAgent->new;
my $auth_header = 'Basic ' . encode_base64( "$user:$password", '' );

sub call_jsonrpc {
    my ( $method, $params ) = @_;
    $params //= {};

    my $req = HTTP::Request->new( 'POST', "$jsonrpc_url/$method" );
    $req->header( 'Content-Type'  => 'application/json' );
    $req->header( 'Authorization' => $auth_header );
    $req->content( encode_json($params) );

    my $resp = $ua->request($req);
    die "Errore HTTP nella chiamata a $method: " . $resp->status_line . "\n"
      unless $resp->is_success;

    my $data = decode_json( $resp->decoded_content );

    if (   ref $data eq 'HASH'
        && exists $data->{error}
        && $data->{error}{code} != 0 )
    {
        die "Errore JSON-RPC nella chiamata a $method: "
          . $data->{error}{message} . "\n";
    }

    return
      ref $data eq 'HASH' && exists $data->{result} ? $data->{result} : $data;
}

my $pagine_resp =
  call_jsonrpc( 'core.listPages', { namespace => $namespace, depth => 0 } );

my @pagine_namespace = map { $_->{id} } @$pagine_resp;

if ( $n > @pagine_namespace ) {
    warn "Richieste $n pagine, ma il namespace ne contiene solo "
      . scalar(@pagine_namespace)
      . "; le mostro tutte.\n";
    $n = @pagine_namespace;
}

@pagine_namespace = shuffle @pagine_namespace;

say $pagine_namespace[$_] for ( 0 .. $n - 1 );
