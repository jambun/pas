#!/usr/bin/env perl6

use Net::HTTP::GET;
use Net::HTTP::POST;
use JSON::Tiny;
use MONKEY-SEE-NO-EVAL;

use lib './lib';
use JSONPretty;

my %config = 
   url  => 'http://localhost:4567',
   user => 'admin',
   pass => 'admin';


my %prompts =
   url  => 'ArchivesSpace backend URL',
   user => 'Username',
   pass => 'Password';

my $PAS_DIR = %*ENV<HOME> ~ '/.pas';
my $CFG_FILE = 'config.json';
my $TMP_FILE = 'last.json';

my Bool $LOUD;
my Bool $COMPACT;
my Int $INDENT-STEP;

sub MAIN(Str  $uri = '/',
              *@pairs,
	 Str  :$cmd = 'show',
         Str  :$user?,
         Str  :$pass?,
         Str  :$url?,
         Str  :$session?,
         Str  :$post?,
         Str  :$alias?,
         Bool :$help=False,
         Bool :$h=False,
         Bool :$compact=False,
         Bool :$c=False,
         Int  :$indent-step?,
         Bool :$verbose=False,
         Bool :$v=False,
         Bool :$prompt=False,
         Bool :$p=False,
	 Bool :$force-login=False,
	 Bool :$f=False) {

    if $help || $h {
       help;
       exit;
    }

    $LOUD = $verbose || $v;
    $COMPACT = $compact || $c;
    $INDENT-STEP = $indent-step || 2;

    my $command = $cmd;

    load_config($url, $user, $pass, $session, $prompt || $p);

    if $alias {
       %config<alias> ||= {};
       my ($from, $to) = $alias.split(':', 2);
       my ($cmd, $als) = $alias.split('!', 2);
       if $cmd && $als {
       	  %config<alias>{$als}:delete if $cmd eq 'delete';
	  save_config;
	  say "Alias .$als. deleted.";
       } elsif $to {
       	  %config<alias>{$from} = $to;
	  save_config;
	  say "Alias .$from. added.";
       } else {
       	  my %aliases = %config<alias>;
	  for %aliases.keys.sort -> $k { say ".$k. {%aliases{$k}}" };
       }
       exit;
    }


    login if $url || $user || $pass || !%config<session> || $force-login || $f;

    my $trailing_non_pair = @pairs.elems > 0 && (@pairs.tail.first !~~ /\=/ ?? @pairs.pop !! '');

    my $post_file = $post;

    if $trailing_non_pair {
       if $trailing_non_pair.IO.e {
       	  $post_file ||= $trailing_non_pair;
       } else {
       	  $command = $trailing_non_pair;
       }
    }

    my $ruri = $uri;
    $ruri ~~ s:g/\. (\w+) \./%config<alias>{$0}/;

    if $post_file {

	say pretty post($ruri, @pairs, slurp($post_file));

    } else {

      	given ($command) {
      	    when ('new') { say pretty update_uri($ruri, '{}', @pairs); }

      	    when ('stub') {
	    	 my $puri = $ruri;
		 $puri ~~ s:g/\/repositories\/\d+/\/repositories\/:repo_id/;
		 $puri ~~ s:g/\d+/:id/;
	    	 my $e = from-json get('/endpoints', ['uri=' ~ $puri, 'method=post']);
		 adieu "Couldn't find endpoint definition" if @($e).elems == 0;
		 my $model = $e.first{'params'}[0][1];
		 $model ~~ s/\w+\(\:(\w+)\)/$0/;

            	 save_tmp(pretty get('/stub/' ~ $model, @pairs));
		 say edit(tmp_file) ?? pretty post($ruri, @pairs, slurp(tmp_file)) !! 'No changes to post.';
	    }

	    when (/edit(.last)?/) {
            	 save_tmp(pretty get($ruri)) unless $0;
		 say edit(tmp_file) ?? pretty post($ruri, @pairs, slurp(tmp_file)) !! 'No changes to post.';
	    }

	    when ('update') { say pretty update_uri($ruri, get($uri), @pairs); }

	    when ('show') { say pretty get($ruri, @pairs); }

	    default { say 'Unknown command: ' ~ $_; }
	}

    }
}

sub pretty($json) {
    if $COMPACT {
       $json;
    } else {
       JSONPretty::Grammar.parse($json, :actions(JSONPretty::Actions.new(step => $INDENT-STEP))).made;
    }
}

sub edit($file) {
    my $mtime = $file.IO.modified;
    shell (%*ENV<EDITOR> || 'emacs') ~ ' ' ~ $file;
    $mtime != $file.IO.modified;
}


sub request($uri, @pairs, $body?) {
    my $url = build_url($uri, @pairs);
    my %header = 'X-Archivesspace-Session' => %config<session>;

    my $response = $body ?? Net::HTTP::POST($url, :%header, :$body) !! Net::HTTP::GET($url, :%header);
		
    if $response.status-line ~~ /412/ {
       login;
       $response = $body ?? Net::HTTP::POST($url, :%header, :$body) !! Net::HTTP::GET($url, :%header);
    }
    $response.body.decode('utf-8');

}


sub update_uri($uri, $json, @pairs) {
    my %hash = from-json $json;
    for @pairs -> $q {
        my ($k, $v) = $q.split('=', 2);

	# pure dodginess
	# terms.0.term > %hash{'terms'}[0]{'term'}
	$k ~~ s:g/<[\w_]>+/\{'{$/}'\}/;
	$k ~~ s:g/\{\'(\d+)\'\}/\[$0\]/;
	$k ~~ s:g/\.//;
	$k = '%hash' ~ $k;
	EVAL $k ~ ' = $v';
    }
    post($uri, @pairs, to-json(%hash));
}


sub post($uri, @pairs, $data) {
    my $body = Buf.new($data.ords);
    request($uri, @pairs, $body);
}


sub get($uri, @pairs = []) {
    request($uri, @pairs);
}


sub build_url($uri, @pairs) {
    my $url = %config<url> ~ $uri;
    $url ~= '?' ~ @pairs.join('&') if @pairs;
    # FIXME: escape this properly
    $url ~~ s:g/\s/\%20/;
    $url;
}


sub load_config($url, $user, $pass, $session, $prompt) {
    if !$prompt && config_file.IO.e {
        %config = from-json slurp(config_file);
	for <url user pass session> { %config{$_} = $::($_) if $::($_) }
    } else {
        for <url user pass> { %config{$_} = $::($_) || prompt_default(%prompts{$_}, %config{$_}) }
    }
}


sub login {
    blurt 'Logging in to ' ~ %config<url> ~ ' with: ' ~ %config<user> ~ '/' ~ %config<pass>;

    my $uri      = '/users/' ~ %config<user> ~ '/login';
    my @pairs    = ["password={%config<pass>}", 'expiring=false'];
    my $body     = Buf.new("password={%config<pass>}".ords);
    my $resp     = Net::HTTP::POST(build_url($uri, @pairs), :$body);

    if $resp.status-line ~~ /200/ {
        %config<session> = (from-json $resp.body.decode('utf-8'))<session>;
	save_config;
    } else {
        adieu 'Log in failed!';
    }
}


sub pas_path($file) {
    $PAS_DIR ~ '/' ~ $file;
}


sub save_pas_file($file, $data) {
    mkdir($PAS_DIR);
    spurt $PAS_DIR ~ '/' ~ $file, $data;
}


sub config_file {
    pas_path $CFG_FILE;
}


sub save_config {
    save_pas_file($CFG_FILE, to-json %config);
}


sub tmp_file {
    pas_path $TMP_FILE;
}


sub save_tmp($data) {
    save_pas_file($TMP_FILE, $data);
}


sub blurt($out) {
    say $out if $LOUD;
}


sub prompt_default($prompt, $default) {
    my $response = prompt $prompt ~ " (default: {$default}):";
    $response ~~ /\w/ ?? $response !! $default;
}


sub adieu(Str $message) {
    say $message;
    exit 1;
}


sub help {
    say q:heredoc/END/;

pas - a commandline client for ArchivesSpace

    pas (switches) uri pairs* cmd?
    pas (swtiches) uri file

    Switches:
    --cmd=command      show (default) | new | edit | update | stub
    --url=url          Set the ArchivesSpace URL.
    --user=username    Set the username.
    --pass=password    Set the password.
    --sess=token       Set the session token.
    --post=file        Post file to uri. Same as `pas uri file`
    --alias=from:to    Alias 'from' to a uri fragment 'to'
    --alias=list       List aliases
    --alias=delete!als Delete alias 'als'
    -h/--help          This.
    -v/--verbose       Be noisy.
    -f/--force-login   Login to ArchivesSpace even if we have a good session.
    -p/--prompt        Prompt for ArchivesSpace connection info even if we already have it.

    Commands:
    show               Get the uri.
    new                Build a record using the pairs and post it.
    edit               Get the uri and present the json in an editor, then post if any changes are made.
    edit.last          Present the last edited json file in an editor, then post if any changes are made.
    update             Get the uri, update it using the pairs and post the resulting json.
    stub               Get a stub record expected by uri, present it in an editor and post if any changes were made.

    Examples:
    pas /repositories
    pas /repositories repo_code=MOO 'name=MOO repo' new
    pas /repositories stub
    pas /repositories myfile.json
    pas /repositories/2 repo_code=MOO update
    pas /repositories/2 edit
    pas --cmd=edit /repositories/2
    pas /schemas
    pas /schemas/resource
    pas /endpoints
    pas /endpoints uri=/repositories method=post
    pas --alias=e:/endpoints
    pas .e.
END
}
