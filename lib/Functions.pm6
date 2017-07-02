use Config;
use Pas::ASClient;
use Pas::Store;
use JSONPretty;

use JSON::Tiny;
use Digest::MD5;
use Crypt::Random;
use Terminal::ANSIColor;

use MONKEY-SEE-NO-EVAL;


my constant   LAST_DIR           = 'last';
my constant   TMP_FILE           = 'last.json';
our constant  HISTORY_FILE       = 'history';
our constant  HISTORY_LENGTH     = 100;
our constant  ENDPOINTS_URI      = '/endpoints';
my constant   SCHEMAS_URI        = '/schemas';
our constant  USER_URI           = '/users/current-user';
our constant  SEARCH_URI         = '/search';
our constant  SEARCH_RECORDS_URI = '/search/records';
my constant   LOGOUT_URI         = '/logout';
our constant  ANON_USER          = 'anon';

my $SAVE_FILE;
my $SCHEMAS;
my $SCHEMAS_PARSED;
my @LAST_URIS = [];
my @ENDPOINTS = [];
my @TAB_TARGETS;

sub last_uris(@uris = ()) is export { @LAST_URIS = @uris if @uris; @LAST_URIS }
sub tab_targets is export { @TAB_TARGETS }
#sub tab_targets is export { |last_uris, |Command.actions, |@TAB_TARGETS }
sub save_file($file) is export { $SAVE_FILE = $file }

my Pas::Store $STORE;
sub store is export { $STORE ||= Pas::Store.new(:dir(%*ENV<HOME> ~ '/.pas')) }

my Config $CFG;
sub config is export { $CFG ||= Config.new(:store(store)) }

my Pas::ASClient $CLIENT;
sub client is export { $CLIENT ||= Pas::ASClient.new(config => config) }

sub cmd_prompt is export { 'pas ' ~ config.attr<user> ~ '> ' }


sub pretty($json) is export {
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


sub page($text) is export {
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


sub schemas(Bool :$reload, Str :$name) is export {
     if $reload || !$SCHEMAS {
	 my $schemas = client.get(SCHEMAS_URI);
	 $SCHEMAS = pretty $schemas;
	 $SCHEMAS_PARSED = from-json $schemas;
     }

     if $name {
	 pretty to-json $SCHEMAS_PARSED{$name};
     } else {
	 $SCHEMAS;
     }
}


sub tmp_file is export {
    store.path(TMP_FILE);
}


sub save_tmp($data) is export {
    store.save(TMP_FILE, $data);
}
