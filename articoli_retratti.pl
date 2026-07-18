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
use Text::CSV;

use constant RW_CSV_URL =>
'https://gitlab.com/crossref/retraction-watch-data/-/raw/main/retraction_watch.csv';

my $namespace = '';
my $protocol  = 'http';
my $host      = 'localhost';
my $basedir   = '/wiki/';
my $user      = $ENV{DOKUWIKI_XMLRPC_USER};
my $password  = $ENV{DOKUWIKI_XMLRPC_PASSWORD};

my $csv_file       = 'retraction_watch.csv';
my $update_csv     = 0;
my $only_retracted = 0;

GetOptions(
    "user=s"         => \$user,
    "password=s"     => \$password,
    "namespace=s"    => \$namespace,
    "host=s"         => \$host,
    "protocol=s"     => \$protocol,
    "basedir=s"      => \$basedir,
    "csv=s"          => \$csv_file,
    "update-csv"     => \$update_csv,
    "only-retracted" => \$only_retracted,
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

# Scarica (se necessario) e carica il database di Retraction Watch
if ( $update_csv || !-e $csv_file ) {
    say STDERR "Scarico il database Retraction Watch in $csv_file...";

    my $resp = $ua->get( RW_CSV_URL, ':content_file' => $csv_file );

    die "Impossibile scaricare il database Retraction Watch: "
      . $resp->status_line . "\n"
      unless $resp->is_success;
}

my %ritrattazioni_doi;
my %ritrattazioni_pmid;

{
    open my $fh, '<:raw', $csv_file
      or die "Impossibile aprire $csv_file: $!\n";

    my $csv = Text::CSV->new( { binary => 1, auto_diag => 1 } )
      or die "Impossibile inizializzare Text::CSV: "
      . Text::CSV->error_diag . "\n";

    my $header = $csv->getline($fh);
    $csv->column_names(@$header);

    my $n = 0;

    while ( my $row = $csv->getline_hr($fh) ) {
        $n++;

        if ($only_retracted) {
            next unless lc( $row->{RetractionNature} // '' ) eq 'retraction';
        }

        my $doi = $row->{OriginalPaperDOI} // '';

        $doi =~ s{^\s*(?:https?://)?(?:dx\.)?doi\.org/}{}i;
        $doi = lc $doi;

        if ( $doi ne '' && $doi ne 'unavailable' ) {
            $ritrattazioni_doi{$doi} = $row;
        }

        my $pmid = $row->{OriginalPaperPubMedID} // '';

        $pmid =~ s/\D//g;

        if ( $pmid ne '' && $pmid != 0 ) {
            $ritrattazioni_pmid{$pmid} = $row;
        }
    }

    close $fh;

    say STDERR "Caricate $n righe dal database Retraction Watch.";
}

my $pagine_resp =
  call_jsonrpc( 'core.listPages', { namespace => $namespace, depth => 0 } );

my @pagine = map { $_->{id} } @$pagine_resp;

say STDERR "Trovate " . scalar(@pagine) . " pagine da analizzare.";

# Per ogni pagina, estraggo DOI e PMID citati
my %doi_citati;
my %pmid_citati;

my $doi_regex =
  qr{(?:https?://)?(?:dx\.)?doi\.org/(10\.\d{4,9}/[^\s\]\|"'<>]+)}i;

my $pmid_regex = qr{
    (?:
        pubmed\.ncbi\.nlm\.nih\.gov/            # formato attuale
      | (?:www\.)?ncbi\.nlm\.nih\.gov/pubmed/   # vecchio formato
    )
    (\d+)
}ix;

for my $pagina (@pagine) {
    my $testo = call_jsonrpc( 'core.getPage', { page => $pagina } );
    next unless defined $testo;

    while ( $testo =~ /$doi_regex/g ) {
        my $doi = $1;
        $doi =~ s/[.,;:\)\]]+$//;
        $doi = lc $doi;
        $doi_citati{$doi}{$pagina} = 1;
    }

    while ( $testo =~ /$pmid_regex/g ) {
        my $pmid = $1;
        $pmid_citati{$pmid}{$pagina} = 1;
    }
}

say STDERR "Trovati "
  . scalar( keys %doi_citati )
  . " DOI e "
  . scalar( keys %pmid_citati )
  . " PMID citati nella wiki.";

# Incrocio delle citazioni trovate con il database Retraction Watch
my %gia_segnalato;
my $c = 0;

sub segnala {
    my ( $pagina, $identificatore, $tipo, $row ) = @_;

    return if $gia_segnalato{"$pagina|||$row"}++;

    $c++;

    say "";
    say "Pagina:        $pagina";
    say "$tipo:" . ( " " x ( 15 - length("$tipo:") ) ) . "$identificatore";
    say "Titolo:        " . ( $row->{Title}            // '' );
    say "Rivista:       " . ( $row->{Journal}          // '' );
    say "Tipo di nota:  " . ( $row->{RetractionNature} // '' );
    say "Data nota:     " . ( $row->{RetractionDate}   // '' );
    say "Motivo:        " . ( $row->{Reason}           // '' );
    say "Link:          " . ( $row->{URLS}             // '' );
}

for my $doi ( sort keys %doi_citati ) {
    next unless exists $ritrattazioni_doi{$doi};

    my $row = $ritrattazioni_doi{$doi};

    for my $pagina ( sort keys %{ $doi_citati{$doi} } ) {
        segnala( $pagina, $doi, 'DOI', $row );
    }
}

for my $pmid ( sort keys %pmid_citati ) {
    next unless exists $ritrattazioni_pmid{$pmid};

    my $row = $ritrattazioni_pmid{$pmid};

    for my $pagina ( sort keys %{ $pmid_citati{$pmid} } ) {
        segnala( $pagina, $pmid, 'PMID', $row );
    }
}

say "";

if ( $c == 1 ) {
    say "Trovata 1 citazione ad un articolo ritrattato/corretto.";
}
else {
    say "Trovate $c citazioni ad articoli ritrattati/corretti.";
}
