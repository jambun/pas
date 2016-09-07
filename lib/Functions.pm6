use Config;
use Pas::ASClient;

use JSON::Tiny;
use Digest::MD5;
use Crypt::Random;
use Terminal::ANSIColor;

use MONKEY-SEE-NO-EVAL;


my $PAS_DIR = %*ENV<HOME> ~ '/.pas';

my constant LAST_DIR       = 'last';
my constant TMP_FILE       = 'last.json';
our constant ENDPOINTS_URI = '/endpoints';
my constant SCHEMAS_URI    = '/schemas';
our constant USER_URI      = '/users/current-user';
my constant LOGOUT_URI     = '/logout';
our constant ANON_USER     = 'anon';

my %PROP_DEFAULTS = loud     => False,
                    compact  => False,
		    page     => True,
		    time     => False,
		    savepwd  => False,
		    indent   => 2;

my $SAVE_FILE;
my $SCHEMAS;
our @LAST_URIS = [];
my @ENDPOINTS = [];
my @TAB_TARGETS;

sub last_uris is export { @LAST_URIS }
sub tab_targets is export { @TAB_TARGETS }
#sub tab_targets is export { |last_uris, |Command.actions, |@TAB_TARGETS }

my Config $CFG;
sub config is export { $CFG ||= Config.new(dir => $PAS_DIR) }

my Pas::ASClient $CLIENT;
sub client is export { $CLIENT ||= Pas::ASClient.new(config => config) }

sub cmd_prompt is export { 'pas ' ~ config.attr<user> ~ '> ' }


sub parse_cmd(Str $cmd) is export {
    my %out;
    my $c = $cmd.trim;
    $c ~~ s/\s* \> \s* (\S+) $/{$SAVE_FILE = $0.Str; ''}/;
    my ($first, @args) = $c.split(/\s+/);
    if $first ~~ /^<[./]>/ { # a uri
	%out<uri> = $first;
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


sub apply_property_defaults(Bool :$force) is export {
    my %props := config.attr<properties>;
    for %PROP_DEFAULTS.kv -> $k, $v {
	%props{$k} = $v if $force || !(%props{$k}:exists);
    }
}


our sub pretty($json) is export {
    if config.attr<properties><compact> || $json !~~ /^<[\{\[]>/ {
	$json;
    } else {
	JSONPretty::prettify($json, config.attr<properties><indent>);
    }
}


sub edit($file) is export {
    my $mtime = $file.IO.modified;
    shell (%*ENV<EDITOR> || 'emacs') ~ ' ' ~ $file;
    $mtime != $file.IO.modified;
}


sub display($text) is export {
    return unless $text;

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


sub modify_json($json, @pairs) is export {
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


sub interpolate($text, $count) is export {
    my $out = $text;
    $out ~~ s:g/'{n}'/$count/;
    $out ~~ s:g/'{h' \s* (\d*) \s* '}'/{random_hex($0.Int || 7)}/;
    $out ~~ s:g/'s:(' (<-[)]>+) ')' /{select_from($0.Str)}/;
    $out ~~ s:g/'h' (\d*) ':(' <-[)]>+ ')' /{random_hex($0.Int || 7)}/;
    $out ~~ s:g/'d:(' <-[)]>+ ')' /{random_date()}/;

    $out ~~ s:g/'(string)'/{random_hex(7)}/;
    $out ~~ s:g/'(date)' /{random_date()}/;

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


sub extract_uris($text) is export {
    $text ~~ m:g/ '"' ( '/' <-[\\ \s "]>+ )  '"'  /;
    @LAST_URIS = ($/.map: { $_[0].Str }).sort.unique;
    $text;
}


sub load_endpoints(Bool :$force) is export {
    return @ENDPOINTS if @ENDPOINTS && !$force;
    
    my $e = client.get(ENDPOINTS_URI).trim;
    if $e ~~ /^ <-[{[]> / {
	say 'No endpoints endpoint!';
	@TAB_TARGETS = [];
#	@TAB_TARGETS = |Command.actions;
	return [];
    }
    $e = from-json $e;
    @ENDPOINTS = $e ~~ Array ?? $e.unique !! [];
    @TAB_TARGETS = |@ENDPOINTS;
#    @TAB_TARGETS = |@ENDPOINTS, |Command.actions;
    @ENDPOINTS;
}


sub schemas(Bool :$reload) is export {
    $SCHEMAS = pretty get(SCHEMAS_URI) if $reload || !$SCHEMAS;
    $SCHEMAS;
}


sub cursor(Int $col, Int $row) {
    print "\e[{$row};{$col}H";
}


sub pas_path($file) is export {
    $PAS_DIR ~ '/' ~ $file;
}


sub save_pas_file($file, $data) {
    mkdir($PAS_DIR ~ '/' ~ LAST_DIR);
    spurt $PAS_DIR ~ '/' ~ $file, $data;
}


sub tmp_file is export {
    pas_path TMP_FILE;
}


sub save_tmp($data) is export {
    save_pas_file(TMP_FILE, $data);
}


sub blurt($out) {
    say $out if config.attr<properties><loud>;
}


sub prompt_default($prompt, $default) {
    my $response = prompt $prompt ~ " (default: {$default}):";
    $response ~~ /\w/ ?? $response !! $default;
}


sub help is export {
    say q:heredoc/END/;

pas - a terminal client for ArchivesSpace

    pas             Start pas interactive client
    pas -e cmd      Evaluate cmd and write output to stdout
    pas -h          This.

END
}


sub shell_help is export {
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
		    set       show pas properties
                     .[prop]  show or set prop
		    help      this
		    quit      exit pas (^d works too)

    say 'help [action]' for detailed help. {colored('... well, not yet', 'red')}

    Use the <tab> key to cycle through completions for uris or actions.

    Command history and standard keybindings.

END
}