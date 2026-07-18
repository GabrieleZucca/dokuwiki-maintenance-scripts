#!/usr/bin/env perl

# Gabriele Zucca
# Ultima modifica: 18/07/2026

use feature 'say';
use strict;
use warnings;
use utf8;
use open qw/:std :utf8/;

use Term::ReadPassword;
use Getopt::Long;
use LWP::UserAgent;
use HTTP::Request;
use JSON::PP qw/encode_json decode_json/;
use MIME::Base64 qw/encode_base64/;
use HTML::Parser;

# Parametri di default
my $namespace = '';
my $protocol  = 'http';
my $host      = 'localhost';
my $basedir   = '/wiki/';

# Prova a leggere username e password tra le variabili di ambiente. Se sono
# specificate nei parametri dello script i valori deiniti ora saranno
# sovrascritti
my $user     = $ENV{DOKUWIKI_XMLRPC_USER};
my $password = $ENV{DOKUWIKI_XMLRPC_PASSWORD};

GetOptions(
    "user=s"      => \$user,
    "password=s"  => \$password,
    "namespace=s" => \$namespace,
    "host=s"      => \$host,
    "protocol=s"  => \$protocol,
    "basedir=s"   => \$basedir,
);

# Se l'utente non è definito né tra le variabili di ambiente né tra i parametri
# dello script => ritorna errore
die 'Utente non definito.' unless defined $user;

# Se la password non è definita né tra le variabili di ambiente né tra i
# parametri dello script => la chiede interattivamente
unless ( defined $password ) {
    die "Password non fornita e nessun terminale disponibile per chiederla "
      . "in modo interattivo.\n"
      unless -t STDIN;

    do {
        $password = read_password("Password per l'utente $user: ");
    } until ( defined $password && $password =~ /\S/ );
}

# Il protocollo deve essere http o https. /i rende la regex case insensitive
die "Protocollo non valido: $protocol!"
  unless $protocol =~ /^http[s]{0,1}$/i;

# Converto il protocollo in lowecase
$protocol = lc $protocol;

# URL base dell'endpoint JSON-RPC
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

# Ottengo l'elenco delle pagine nel namespace di interesse
my $pagine_resp =
  call_jsonrpc( 'core.listPages', { namespace => $namespace, depth => 0 } );

my @pagine = map { $_->{id} } @$pagine_resp;

my $c = 0;    # Contatore

# Per tutte le pagine nel namespace di interesse...
for my $pagina (@pagine) {

    # Chiedo a DokuWiki di renderizzare la pagina in HTML
    my $html = call_jsonrpc( 'core.getPageHTML', { page => $pagina } );
    
    next unless defined $html;

    # Cerco i tag <a> con class="wikilink2"
    my $parser = HTML::Parser->new(
        start_h => [
            sub {
                my ( $tag, $attr ) = @_;
                return unless $tag eq 'a';
                return
                  unless defined $attr->{class}
                  && $attr->{class} eq 'wikilink2';

                my $link = $attr->{'data-wiki-id'}
                  // '(attributo data-wiki-id mancante)';
                say "Link inesistente nella pagina $pagina => $link";
                $c++;
            },
            'tagname, attr'
        ],
    );

    $parser->parse($html);
    $parser->eof;
}

if ( $c == 1 ) {
    say "\nTrovato 1 link inesistente.";
}
else {
    say "\nTrovati $c link inesistenti.";
}
