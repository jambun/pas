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

my %PROP_DEFAULTS = loud     => False,
                    compact  => False,
		    page     => True,
		    time     => False,
		    savepwd  => False,
		    indent   => 2;

my $SAVE_FILE;
my $SCHEMAS;
my @LAST_URIS = [];
my @TAB_TARGETS;

my Config $CFG;
sub config { $CFG ||= Config.new(dir => $PAS_DIR) }

class Command {
    has Str $.action;
    has     @.args;
    has Str $.qualifier = '';
    has     $!first;

    my constant ACTIONS = <show update create edit stub post login run
                           endpoints schemas config session user
                           last alias set help quit>;

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

	my $model;
	for $e.first<params>.List {
	    $model = $_[1];
	    last if $model ~~ s/'JSONModel(:' (\w+) ')'/$0/;
	}

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

    method run {
	if $!first.IO.e {
	    my @cmds = slurp($!first).split("\n");
	    for @cmds -> $line {
		say cmd_prompt() ~ $line;
		run_cmd $line;
	    }
	} else {
	    'Script file not found: ' ~ $!first;
	}
    }
    
    method session {
	if $!first {
	    if $!qualifier eq 'delete' {
		delete_session($!first);
	    } else {
		switch_to_session($!first);
	    }
	} else {
	    (for config.attr<sessions>.kv -> $k, $v {
		    (
			$v<url>,
			colored($k, config.attr<user> eq $k ?? 'bold green' !! 'bold white'),
			DateTime.new($v<time>).local.truncated-to('second')
		    ).join("\t");
		}).join("\n");
	}
    }

    method user {
	pretty get '/users/current-user';
    }
    
    method endpoints {
    	load_endpoints.join("\n");
    }

    method schemas {
	schemas($!qualifier eq 'reload');
    }
    
    method config {
    	config.json;
    }

    method last {
	slurp tmp_file;
    }
    
    method alias {
    	alias_cmd($!first);
    }

    method set {
	my %prop := config.attr<properties>;
	unless $!qualifier {
	    if $!first eq 'defaults' {
		apply_property_defaults(True);
		config.save;
		return 'Properties reset to default values';
	    } else {
		return (%prop.keys.sort.map: { $_ ~ "\t" ~ %prop{$_}  }).join("\n");
	    }
	}

	unless %prop.keys.grep($!qualifier) {
	    return 'Unknown property: ' ~ $!qualifier;
	}

	given %prop{$!qualifier}.WHAT {
	    when Bool {
		if $!first eq '0' | 'off' | 'false' {
		    %prop{$!qualifier} = False;
		    config.save;
		    $!qualifier ~ ' off';
		} elsif $!first ~~ /./ {
		    %prop{$!qualifier} = True;
		    config.save;
		    $!qualifier ~ ' on';
		} else {
		    $!qualifier ~ (%prop{$!qualifier} ?? ' on' !! ' off');
		}
	    }
	    when Int {
		if so $!first.Int {
		    %prop{$!qualifier} = $!first.Int;
		    config.save;
		    $!qualifier ~ ' ' ~ %prop{$!qualifier};
		} elsif $!first ~~ /./ {
		    $!qualifier ~ ' must be a number';
		} else {
		    $!qualifier ~ ' ' ~ %prop{$!qualifier};
		}
	    }
	}
    }

    method help {
	shell_help;
    }

    method quit {
	linenoiseHistorySave(pas_path HIST_FILE);
    	say 'Goodbye';    	
	exit;
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
	 Str  :$e?,
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

    my %props := config.attr<properties>;
    %props<loud>    = True if $verbose || $v;
    %props<compact> = True if $compact || $c;
    %props<indent>  = $indent-step if $indent-step;
    %props<page>    = False if $no-page || $n;

    apply_property_defaults;
    
    if $alias {
        alias_cmd($alias);
        exit;
    }

    login if $url || $user || $pass || !config.attr<session> || $force-login || $f;

    if $e {
	run_cmd $e;
	exit;
    }

    if $shell || $s || !$uri {
       linenoiseHistoryLoad(pas_path HIST_FILE);
       linenoiseHistorySetMaxLen(HIST_LENGTH);

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
	   for (|@LAST_URIS, |@TAB_TARGETS).map({
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
       });

       while (my $line = linenoise cmd_prompt).defined {
	   run_cmd $line;
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


sub cmd_prompt { 'pas ' ~ config.attr<user> ~ '> ' }


sub run_cmd(Str $line) {
    return unless $line.trim;
	   
    linenoiseHistoryAdd($line.trim);

    return if $line ~~ /^ '#' /; 

    my %cmd = parse_cmd($line);

    my $intime = now;
    display Command.new(action => %cmd<action>, args => %cmd<args>.list).execute;
    say '[' ~ (now - $intime) ~ 's]' if config.attr<properties><time>;
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


sub apply_property_defaults(Bool $force = False) {
    my %props := config.attr<properties>;
    for %PROP_DEFAULTS.kv -> $k, $v {
	%props{$k} = $v if $force || !(%props{$k}:exists);
    }
}


sub resolve_aliases(Str $text) {
    $text.subst: /\. (\w+) \./, -> { config.attr<alias>{$0} }, :g;
}


sub pretty($json) {
    if config.attr<properties><compact> || $json !~~ /^<[\{\[]>/ {
	$json;
    } else {
	JSONPretty::Grammar.parse($json, :actions(JSONPretty::Actions.new(step => config.attr<properties><indent>))).made;
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

    if config.attr<properties><page> && q:x/tput lines/.chomp.Int < $text.lines {
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
    my %header = 'Connection' => 'close';   # << this works around a bug in Net::HTTP

    %header<X-Archivesspace-Session> = config.attr<token> if config.attr<token>;
    
    blurt %header;
    blurt $url;
    
    my $response = $body ?? Net::HTTP::POST($url, :%header, :$body) !! Net::HTTP::GET($url, :%header);

    if $response.status-line ~~ /412/ {
        login;
	%header<X-Archivesspace-Session> = config.attr<token> if config.attr<token>;
       	$response = $body ?? Net::HTTP::POST($url, :%header, :$body) !! Net::HTTP::GET($url, :%header);
    }
    
    blurt $response.status-line;

    if $response.status-line ~~ /412/ {
	say 'The session was bad. Tried to login again, but it is still not working.';
	say "Say 'login.prompt' to re-enter login details, or 'session' to find a good session";
    }

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
    @LAST_URIS = ($/.map: { $_[0].Str }).sort.unique;
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


sub load_endpoints {
    my $e = from-json(get(ENDPOINTS_URI));
    my @endpoints = $e ~~ Array ?? $e.unique !! [];
    @TAB_TARGETS = |@endpoints, |Command.actions;
    @endpoints;
}


sub schemas(Bool $reload = False) {
    $SCHEMAS = pretty get(SCHEMAS_URI) if $reload || !$SCHEMAS;
    $SCHEMAS;
}


sub cursor(Int $col, Int $row) {
    print "\e[{$row};{$col}H";
}


sub switch_to_session(Str $name) {
    my $sess = config.attr<sessions>{$name};
    return 'Unknown session: ' ~ $name unless $sess;

    config.attr<url>   = $sess<url>;
    config.attr<user>  = $sess<user>;
    config.attr<pass>  = $sess<pass>;
    config.attr<time>  = $sess<time>;
    config.attr<token> = $sess<token>;
    config.save;
    load_endpoints;
    
    'Swtiched to session: ' ~ $name;
}


sub delete_session(Str $name) {
    my $sess = config.attr<sessions>{$name};
    return 'Unknown session: ' ~ $name unless $sess;

    return "Can't delete current session!" if $sess<token> eq config.attr<token>;

    config.attr<sessions>{$name}:delete;
    config.save;

    'Deleted session: ' ~ $name;
}


sub login {
    blurt 'Logging in to ' ~ config.attr<url> ~ ' as ' ~ config.attr<user>;

    unless config.attr<pass> {
	config.prompt_for('pass', 'Enter password for ' ~ config.attr<user>);
    }
    
    my $uri      = '/users/' ~ config.attr<user> ~ '/login';
    my @pairs    = ["password={config.attr<pass>}"];
    my %header   = 'Connection' => 'close';
    my $resp     = Net::HTTP::POST(build_url($uri, @pairs), :%header);

    if $resp.status-line ~~ /200/ {
        config.attr<token> = (from-json $resp.body.decode('utf-8'))<session>;
	config.attr<time> = time;
	config.attr<sessions>{config.attr<user>} = {
	    url   => config.attr<url>,
	    user  => config.attr<user>,
	    pass  => config.attr<pass>,
	    token => config.attr<token>,
	    time  => config.attr<time>
	};
	config.save;
	load_endpoints;
	'Successfully logged in to ' ~ config.attr<url> ~ ' as ' ~ config.attr<user>;
    } else {
	@TAB_TARGETS = Command.actions;
	config.attr<token> = '';
        say 'Log in failed!';
	'';
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
    say $out if config.attr<properties><loud>;
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
                     .last    using last edited record
		    stub      create from an edited stub
                     .[n]     post n times
		    post      post a file (default if last arg is a file)

    other actions:  login     force a login
                     .prompt  prompt for details
	            user      show the current user
                    session   show sessions or switch to a session
                     .delete  delete a session
                    run       run a pas script file
	            endpoints show the available endpoints
		    schemas   show all record schemas
		    config    show pas config
                    last      show the last saved temp file
		    alias     show or update aliases
		    set       show pas properties
                     .[prop]  show or set prop
		    help      this
		    quit      exit pas (^d works too)

    say 'help [action]' for detailed help. {colored('... well, not yet', 'red')}

    Use the <tab> key to cycle through completions for uris or actions.

    Command history and standard keybindings.

END
}
