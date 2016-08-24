#!/usr/bin/env perl6

use lib './lib';
use Config;
use JSONPretty;

use Net::HTTP::GET;
use Net::HTTP::POST;
use JSON::Tiny;
use Linenoise;

use MONKEY-SEE-NO-EVAL;

my $PAS_DIR = %*ENV<HOME> ~ '/.pas';
my constant TMP_FILE = 'last.json';
my constant HIST_FILE = 'history';
my constant HIST_LENGTH = 100;
my constant ENDPOINTS_URI = '/endpoints';

my Bool $LOUD;
my Bool $COMPACT;
my Bool $PAGE;
my Int $INDENT-STEP;

my Config $CFG;
sub config { $CFG ||= Config.new(dir => $PAS_DIR) }

class Command {
    has Str $.action;
    has     @.args;
    has Str $.qualifier = '';
    has     $!first;

    my %state = verbose => False,
       	        compact => False;
		
    my constant ACTIONS = <show update create edit stub post login endpoints config alias set help quit>;

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
	edit(tmp_file) ?? pretty post($!first, @!args, slurp(tmp_file)) !! 'No changes to post.';
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

    method config {
    	config.json;
    }

    method alias {
    	alias_cmd($!first);
    }

    method set {
        unless $!qualifier eq 'loud' | 'compact' | 'page' {
	    return 'Unknown property: ' ~ $!qualifier;
	}

	if $!first eq '0' | 'off' | 'false' {
	    $::($!qualifier.uc) = False;
	    $!qualifier.wordcase ~ ' off';
	} elsif $!first ~~ /./ {
	    $::($!qualifier.uc) = True;
	    $!qualifier.wordcase ~ ' on';
	} else {
	    $!qualifier.wordcase ~ ($::($!qualifier.uc) ?? ' on' !! ' off');
	}
    }

    method help {
        self.actions.join("\n");
    }

    method quit {
    	'Goodbye';    	
    }
}


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

    $LOUD = $verbose || $v;
    $COMPACT = $compact || $c;
    $INDENT-STEP = $indent-step || 2;
    $PAGE = !($no-page || $n);

    if $alias {
        alias_cmd($alias);
        exit;
    }

    login if $url || $user || $pass || !config.attr<session> || $force-login || $f;


    if $shell || $s {
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
	   my @m = $last.split('/');
	   my $mf = @m.pop;
	   for @tab_targets.map({
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
	   }).grep(/./).sort -> $m {
       	        linenoiseAddCompletion($c, $prefix ~ $m);
	   }

#	   for @tab_targets.grep(/^ "$last" /).sort -> $cmd {
#       	        linenoiseAddCompletion($c, $prefix ~ $cmd);
#    	   }
       });


       while (my $line = linenoise 'pas> ').defined {
       	   next unless $line.trim;
       	   linenoiseHistoryAdd($line);
	   my %cmd = parse_cmd($line);

    	   display Command.new(action => %cmd<action>, args => %cmd<args>.list).execute;

	   last if %cmd<action> eq 'quit';
       }

       linenoiseHistorySave(pas_path HIST_FILE);

    } else {

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
    if $c ~~ /^<[./]>/ { # a uri
	my ($uri, @args) = $c.split(/\s+/);
	%out<uri> = resolve_aliases($uri);
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
	my ($action, @args) = $c.split(/\s+/);
	%out<action> = $action;
	%out<args> = @args;
    }
    %out;
}


sub resolve_aliases(Str $text) {
    $text.subst: /\. (\w+) \./, -> { config.attr<alias>{$0} }, :g;
}


sub pretty($json) {
    if $COMPACT || $json !~~ /^<[\{\[]>/ {
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


sub display($text) {
    return unless $text ~~ /./;

    if $PAGE && q:x/tput lines/.chomp.Int < $text.lines {
        page($text);
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

    $response.body.decode('utf-8');
}


sub modify_json($json, @pairs) {
    my %hash = from-json $json;
    for @pairs -> $q {
        my ($k, $v) = $q.split('=', 2);

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


sub update_uri($uri, $json, @pairs) {
    post($uri, @pairs, modify_json($json, @pairs));

}


sub post($uri, @pairs, $data) {
    my $body = Buf.new($data.ords);
    request($uri, @pairs, $body);
}


sub get($uri, @pairs = []) {
    request($uri, @pairs);
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
    --post=file        Post file to uri. Same as `pas uri file`.
    --alias=from:to    Alias 'from' to a uri fragment 'to'.
    --alias=list       List aliases.
    --alias=delete!als Delete alias 'als'.
    -s/--shell         Enter interactive shell.
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
