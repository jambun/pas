#!/usr/bin/env perl6

use lib './lib';
use Config;
use JSONPretty;

use Net::HTTP::GET;
use Net::HTTP::POST;
use JSON::Tiny;
use Linenoise;
use Digest::MD5;
use Crypt::Random;
use Terminal::ANSIColor;

use MONKEY-SEE-NO-EVAL;

my $PAS_DIR = %*ENV<HOME> ~ '/.pas';

my constant TMP_FILE      = 'last.json';
my constant HIST_FILE     = 'history';
my constant HIST_LENGTH   = 100;
my constant ENDPOINTS_URI = '/endpoints';
my constant SCHEMAS_URI   = '/schemas';

my %PROP = loud    => False,
           compact => False,
	   page    => True,
	   time    => False,
	   indent  => 2;

my $SAVE_FILE;
my $SCHEMAS;
my @LAST_URIS = [];

my Config $CFG;
sub config { $CFG ||= Config.new(dir => $PAS_DIR) }

class Command {
    has Str $.action;
    has     @.args;
    has Str $.qualifier = '';
    has     $!first;

    my constant ACTIONS = <show update create edit stub post login
                           endpoints schemas config alias set help quit>;

    method actions { ACTIONS }

    method execute {
    	($!action, $!qualifier) = $!action.split('.', 2);
    	@!args ||= [''];
	$!first = @!args.shift;
	$!qualifier ||= '';
	(ACTIONS.grep: $!action) ?? self."$!action"() !! "Unknown action: $!action";
    }

    method show {
        pretty get($!first, @!args);
    }

    method update {
	pretty update_uri($!first, get($!first), @!args);
    }

    method create {
      	pretty update_uri($!first, '{}', @!args);
    }

    method edit {
        save_tmp(pretty get($!first)) unless $!qualifier eq 'last';
	edit(tmp_file) ?? pretty post($!first, @!args, slurp(tmp_file)) !! 'No changes to post.';
    }

    method stub {
	my $puri = $!first;
	$puri ~~ s:g/\/repositories\/\d+/\/repositories\/:repo_id/;
	$puri ~~ s:g/\d+/:id/;
	my $e = from-json get('/endpoints', ['uri=' ~ $puri, 'method=post']);
	return "Couldn't find endpoint definition" if @($e).elems == 0;
	my $model = $e.first{'params'}[0][1];
	$model ~~ s/\w+\(\:(\w+)\)/$0/;

        save_tmp(pretty get('/stub/' ~ $model, @!args));

	my Int $times = (so $!qualifier.Int) ?? $!qualifier.Int !! 1;
	if edit(tmp_file) {
	    my $out = '';
	    my $json = slurp(tmp_file);
	    for ^$times -> $c { $out ~= $c+1 ~ ' ' ~ pretty post($!first, @!args, interpolate($json, $c+1)) }
	    $out;
	} else {
	    'No changes to post.';
	}
    }

    method post {
	my $post_file = @!args.pop;
	pretty post($!first, @!args, slurp($post_file));
    }

    method login {
	config.prompt if $!qualifier eq 'prompt';
    	login;
    }

    method endpoints {
    	endpoints.join("\n");
    }

    method schemas {
	schemas($!qualifier eq 'reload');
    }
    
    method config {
    	config.json;
    }

    method alias {
    	alias_cmd($!first);
    }

    method set {
	unless $!qualifier {
	    return (%PROP.keys.sort.map: { $_ ~ "\t" ~ %PROP{$_}  }).join("\n");
	}

	unless %PROP.keys.grep($!qualifier) {
	    return 'Unknown property: ' ~ $!qualifier;
	}

	given %PROP{$!qualifier}.WHAT {
	    when Bool {
		if $!first eq '0' | 'off' | 'false' {
		    %PROP{$!qualifier} = False;
		    $!qualifier.wordcase ~ ' off';
		} elsif $!first ~~ /./ {
		    %PROP{$!qualifier} = True;
		    $!qualifier.wordcase ~ ' on';
		} else {
		    $!qualifier.wordcase ~ (%PROP{$!qualifier} ?? ' on' !! ' off');
		}
	    }
	    when Int {
		if so $!first.Int {
		    %PROP{$!qualifier} = $!first.Int;
		    $!qualifier.wordcase ~ ' ' ~ %PROP{$!qualifier};
		} elsif $!first ~~ /./ {
		    $!qualifier.wordcase ~ ' must be a number';
		} else {
		    $!qualifier.wordcase ~ ' ' ~ %PROP{$!qualifier};
		}
	    }
	}
    }

    method help {
	shell_help;
    }

    method quit {
    	'Goodbye';    	
    }
}


sub MAIN(Str  $uri = '',
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
         Bool :$shell=False,
         Bool :$s=False,
         Int  :$indent-step?,
         Bool :$verbose=False,
         Bool :$v=False,
         Bool :$prompt=False,
         Bool :$p=False,
         Bool :$no-page=False,
         Bool :$n=False,
	 Bool :$force-login=False,
	 Bool :$f=False) {


    if $help || $h {
	help;
	exit;
    }

    config.load($url, $user, $pass, $session, $prompt || $p);

    %PROP<loud>    = $verbose || $v;
    %PROP<compact> = $compact || $c;
    %PROP<indent>  = $indent-step || 2;
    %PROP<page>    = !($no-page || $n);

    if $alias {
        alias_cmd($alias);
        exit;
    }

    login if $url || $user || $pass || !config.attr<session> || $force-login || $f;


    if $shell || $s || !$uri {
       linenoiseHistoryLoad(pas_path HIST_FILE);
       linenoiseHistorySetMaxLen(HIST_LENGTH);

       my @tab_targets = |Command.actions, |endpoints;
       linenoiseSetCompletionCallback(-> $line, $c {
       	   my $prefix  = '';
	   my $last = $line;
	   if $line ~~ /(.* \s+) (<[\S]>+ $)/ {
	      $prefix = $0;
	      $last = $1;
	   }

	   # FIXME: this is pretty worky, but totally gruesome
	   # making tab targets work when param bits of uris (eg :id) have values
	   my @m = $last.split('/');
	   my $mf = @m.pop;
	   for (|@LAST_URIS, |@tab_targets).map({
	       my @t = .split('/');
	       if @m.elems >= @t.elems {
	       	  '';
	       } else {
	       my @out;
	       for zip @m, @t -> ($m, $t) {
	       	   @out.push($m) if $t ~~ /^ ':' / || $t eq $m;
	       }
	       if @out.elems == @m.elems && @t[@m.elems] ~~ /^ "$mf" / {
	       	  (|@m, |@t[@m.elems .. @t.end]).join('/');
	       } else {
	       	  '';
	       }
	       }
	   }).grep(/./) -> $m {
       	        linenoiseAddCompletion($c, $prefix ~ $m);
	   }

#	   for @tab_targets.grep(/^ "$last" /).sort -> $cmd {
#       	        linenoiseAddCompletion($c, $prefix ~ $cmd);
#    	   }
       });


       while (my $line = linenoise 'pas> ').defined {
       	   next unless $line.trim;
       	   linenoiseHistoryAdd($line.trim);
	   my %cmd = parse_cmd($line);

	   my $intime = now;
    	   display Command.new(action => %cmd<action>, args => %cmd<args>.list).execute;
	   say '[' ~ (now - $intime) ~ 's]' if %PROP<time>;

	   last if %cmd<action> eq 'quit';
       }

       linenoiseHistorySave(pas_path HIST_FILE);

    } else {
	# FIXME: should be using a common command parser
        my $command = $cmd;
    	my $post_file = $post;
    	my $trailing_non_pair = @pairs.elems > 0 && (@pairs.tail.first !~~ /\=/ ?? @pairs.pop !! '');

    	if $trailing_non_pair {
       	    if $trailing_non_pair.IO.e {
       		$post_file ||= $trailing_non_pair;
		$command ||= 'post';
            } else {
       		$command = $trailing_non_pair;
       	    }
    	}

    	my @args = @pairs;
    	@args.unshift(resolve_aliases($uri)) if $uri;

    	display Command.new(action => $command, args => @args.list).execute;
    }
}


sub parse_cmd(Str $cmd) {
    my %out;
    my $c = $cmd.trim;
    $c ~~ s/\s* \> \s* (\S+) $/{$SAVE_FILE = $0.Str; ''}/;
    my ($first, @args) = $c.split(/\s+/);
    if $first ~~ /^<[./]>/ { # a uri
	%out<uri> = resolve_aliases($first);
	my $action = 'show';
	my $trailing_non_pair = @args.elems > 0 && (@args.tail.first !~~ /\=/ ?? @args.pop !! '');

	if $trailing_non_pair {
       	    if $trailing_non_pair.IO.e {
		$action = 'post';
       		@args.push($trailing_non_pair);
            } else {
       		$action = $trailing_non_pair;
            }
	}

	%out<action> = $action;
	@args.unshift(%out<uri>);
	%out<args> = @args;
    } else {
	%out<action> = $first;
	%out<args> = @args;
    }
    %out;
}


sub resolve_aliases(Str $text) {
    $text.subst: /\. (\w+) \./, -> { config.attr<alias>{$0} }, :g;
}


sub pretty($json) {
    if %PROP<compact> || $json !~~ /^<[\{\[]>/ {
	$json;
    } else {
	JSONPretty::Grammar.parse($json, :actions(JSONPretty::Actions.new(step => %PROP<indent>))).made;
    }
}


sub edit($file) {
    my $mtime = $file.IO.modified;
    shell (%*ENV<EDITOR> || 'emacs') ~ ' ' ~ $file;
    $mtime != $file.IO.modified;
}


sub display($text) {
    return unless $text ~~ /./;

    if $SAVE_FILE {
	spurt $SAVE_FILE, $text;
	$SAVE_FILE = '';
	return;
    }

    if %PROP<page> && q:x/tput lines/.chomp.Int < $text.lines {
        page $text;
    } else {
        say $text;
    }
}


sub page($text) {
    save_tmp($text);
    shell (%*ENV<PAGER> || 'less') ~ ' ' ~ tmp_file;
}


sub request($uri, @pairs, $body?) {
    my $url = build_url($uri, @pairs);
    my %header = 'X-Archivesspace-Session' => config.attr<session>,
       	       	 'Connection'              => 'close';   # << this works around a bug in Net::HTTP

    my $response = $body ?? Net::HTTP::POST($url, :%header, :$body) !! Net::HTTP::GET($url, :%header);

    if $response.status-line ~~ /412/ {
        login;
       	$response = $body ?? Net::HTTP::POST($url, :%header, :$body) !! Net::HTTP::GET($url, :%header);
    }
    
    blurt $response.status-line;

    $response.body.decode('utf-8');
}


sub modify_json($json, @pairs) {
    my %hash = from-json $json;
    for @pairs -> $q {
        my ($k, $v) = $q.split('=', 2);

	$v = True if $v eq 'true';
	$v = False if $v eq 'false';

# FIXME: trying to avoid the EVAL ...
#	my @binder;
#	@binder[0] = %hash;
#        for $k.split('.').kv -> $ix, $t {
#	    if $t ~~ /^ \d+ $/ {
#	       @binder[$ix + 1] := @binder[$ix][$t];       
#	    } else {
#	       @binder[$ix + 1] := @binder[$ix]{$t};
#	    }
#	}
# doesn't work :( - says Str is immutable
#	@binder.tail.first = $v;

	# pure dodginess
	# terms.0.term > %hash{'terms'}[0]{'term'}
	$k ~~ s:g/<:L><[\w_]>*/\{'{$/}'\}/;
	$k ~~ s:g/ \. (\d+) \. /\[$0\]/;
	$k = '%hash' ~ $k;

	EVAL $k ~ ' = $v';
    }
    to-json(%hash);
}


sub interpolate($text, $count) {
    my $out = $text;
    $out ~~ s:g/'{n}'/$count/;
    $out ~~ s:g/'{h' \s* (\d*) \s* '}'/{random_hex($0.Int || 7)}/;
    $out ~~ s:g/'s:(' (<-[)]>+) ')' /{select_from($0.Str)}/;
    $out ~~ s:g/'h' (\d*) ':(' <-[)]>+ ')' /{random_hex($0.Int || 7)}/;
    $out ~~ s:g/'d:(' <-[)]>+ ')' /{random_date()}/;
    $out;
}


sub random_hex(Int $length) {
    Digest::MD5.new.md5_hex(crypt_random().Str).substr(0, $length);
}


sub select_from($text) {
    my @a = $text.split('|');
    @a[crypt_random_uniform(@a.elems)];
}


sub random_date {
    # lazy, bad, never mind
    crypt_random_uniform(300)+1715 ~ '-0' ~ crypt_random_uniform(9)+1 ~ '-' ~ crypt_random_uniform(19)+10;
}


sub update_uri($uri, $json, @pairs) {
    post($uri, @pairs, modify_json($json, @pairs));

}


sub post($uri, @pairs, $data) {
    my $body = Buf.new($data.ords);
    request($uri, @pairs, $body);
}


sub get($uri, @pairs = []) {
    extract_uris request($uri, @pairs);
}


sub extract_uris($text) {
    $text ~~ m:g/ '"' ( '/' <-[\\ \s "]>+ )  '"'  /;
    @LAST_URIS = $/.map: { $_[0].Str };
    $text;
}


sub build_url($uri, @pairs) {
    my $url = config.attr<url> ~ $uri;
    $url ~= '?' ~ @pairs.join('&') if @pairs;
    # FIXME: escape this properly
    $url ~~ s:g/\s/\%20/;
    $url;
}


sub alias_cmd($alias) {
    config.attr<alias> ||= {};
    my ($from, $to) = $alias.split(':', 2);
    my ($cmd, $als) = $alias.split('!', 2);
    if $cmd && $als {
        config.attr<alias>{$als}:delete if $cmd eq 'delete';
        config.save;
        "Alias .$als. deleted.";
    } elsif $to {
       	config.attr<alias>{$from} = $to;
	config.save;
	"Alias .$from. added.";
    } else {
       	my %aliases = config.attr<alias>;
	(%aliases.keys.sort.map({ ".$_.\t{%aliases{$_}}" })).join("\n");
    }
}


sub endpoints {
    from-json(get(ENDPOINTS_URI)).unique;
}


sub schemas(Bool $reload = False) {
    $SCHEMAS = pretty get(SCHEMAS_URI) if $reload || !$SCHEMAS;
    $SCHEMAS;
}

sub cursor(Int $col, Int $row) {
    print "\e[{$row};{$col}H";
}

sub login {
    blurt 'Logging in to ' ~ config.attr<url> ~ ' with: ' ~ config.attr<user> ~ '/' ~ config.attr<pass>;

    my $uri      = '/users/' ~ config.attr<user> ~ '/login';
    my @pairs    = ["password={config.attr<pass>}", 'expiring=false'];
    my $body     = Buf.new("password={config.attr<pass>}".ords);
    my $resp     = Net::HTTP::POST(build_url($uri, @pairs), :$body);

    if $resp.status-line ~~ /200/ {
        config.attr<session> = (from-json $resp.body.decode('utf-8'))<session>;
	config.save;
	'Successfully logged in to ' ~ config.attr<url> ~ ' as ' ~ config.attr<user>;
    } else {
        'Log in failed!';
    }
}


sub pas_path($file) {
    $PAS_DIR ~ '/' ~ $file;
}


sub save_pas_file($file, $data) {
    mkdir($PAS_DIR);
    spurt $PAS_DIR ~ '/' ~ $file, $data;
}


sub tmp_file {
    pas_path TMP_FILE;
}


sub save_tmp($data) {
    save_pas_file(TMP_FILE, $data);
}


sub blurt($out) {
    say $out if %PROP<loud>;
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

    pas
    pas (switches) uri pairs* cmd?
    pas (swtiches) uri file

    Switches:
    --cmd=command      show (default) | new | edit | update | stub
    --url=url          Set the ArchivesSpace URL.
    --user=username    Set the username.
    --pass=password    Set the password.
    --sess=token       Set the session token.
    --post=file        Post file to uri. Same as `pas uri file`.
    --alias=from:to    Alias 'from' to a uri fragment 'to'.
    --alias=list       List aliases.
    --alias=delete!als Delete alias 'als'.
    -s/--shell         Enter interactive shell. Default if no arguments provided.
    -h/--help          This.
    -v/--verbose       Be noisy.
    -n/--no-page       Disable paging long results.
    -f/--force-login   Login to ArchivesSpace even if we have a good session.
    -p/--prompt        Prompt for ArchivesSpace connection info even if we already have it.

    Commands:
    show               Get the uri.
    new                Build a record using the pairs and post it.
    edit               Get the uri and present the json in an editor, then post if any changes are made.
    edit.last          Present the last edited json file in an editor, then post if any changes are made.
    update             Get the uri, update it using the pairs and post the resulting json.
    stub               Get a stub record expected by uri, present it in an editor and post if any changes were made.
    stub.[n]           Create n records from the stub. Use {n} or {h} to interpolate sequence numbers or random hex.
								  
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


sub shell_help {
    qq:heredoc/END/;

    pas shell help

    uri pairs* action? [ > file ]
    uri pairs* file
    action args* [ > file ]

    uri actions:    show      show (default)
		    update    update with the pairs
		    create    create using the pairs
		    edit      edit to update
		    stub      create from an edited stub
		    post      post a file (default if last arg is a file)

    other actions:  login     force a login
		    endpoints show the available endpoints
		    schemas   show all record schemas
		    config    show pas config
		    alias     show or update aliases
		    set       show or update pas properties
		    help      this
		    quit      exit pas (^d works too)

    say 'help [action]' for detailed help. {colored('... well, not yet', 'red')}

    Use the <tab> key to cycle through completions for uris or actions.

    Command history and standard keybindings.

END
}
