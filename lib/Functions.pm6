use Config;
use Pas::ASClient;
use Pas::Store;
use Pas::Logger;
use JSONPretty;
use XMLPretty;

use JSON::Tiny;
use Digest::MD5;
use Crypt::Random;
use Terminal::ANSIColor;


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

my $SAVE_FILE;
my $SAVE_APPEND;
my $SCHEMAS;
my $SCHEMAS_PARSED;
my @LAST_URIS = [];
my @ENDPOINTS = [];
my @TAB_TARGETS;

my @SCHEDULES = [];

sub last_uris(@uris = ()) is export { @LAST_URIS = @uris if @uris; @LAST_URIS }
sub tab_targets is export { @TAB_TARGETS }
#sub tab_targets is export { |last_uris, |Command.actions, |@TAB_TARGETS }
sub save_file($file, $append) is export { $SAVE_FILE = $file; $SAVE_APPEND = $append; }

sub schedules is export { @SCHEDULES = grep { $_<promise>.status !~~ Kept }, @SCHEDULES }

my Pas::Store $STORE;
sub store is export { $STORE ||= Pas::Store.new(:dir(%*ENV<HOME> ~ '/.pas')) }

my Config $CFG;
sub config is export { $CFG ||= Config.new(:store(store)) }

my Pas::Logger $LOGGER;
sub logger is export { $LOGGER ||= Pas::Logger.new(:config(config)); }

my Pas::ASClient $CLIENT;
sub client is export { $CLIENT ||= Pas::ASClient.new(:config(config), :log(logger)) }

sub cmd_prompt is export {
    my $host = config.attr<url>;
    if ($host ~~ /localhost\:(\d+)$/) {
        $host = $0;
    } else {
        $host ~~ s/ 'http://' (<-[\.\:]>+) .* /$0/;
    }
    my $anon = config.attr<properties><anon> ?? "(anon)" !! '';
    sprintf("pas %s %s%s > ", $host, config.attr<user>, $anon);
}


sub pretty($json is copy) is export {
    return $json if config.attr<properties><compact>;

    if $json ~~ /^<[\{\[]>/ {
	JSONPretty::prettify($json, config.attr<properties><indent>);
    } elsif $json ~~ /^<[\<]>/ {
	XMLPretty::prettify($json, config.attr<properties><indent>);
	# a rare xml response - hack it
#	$json ~~ s:g/ ('</' <-[\>]>+ '>') /$0\n/;
#	$json ~~ s:g/ ('<?' <-[\>]>+ '>') /$0\n/;
#	$json ~~ s:g/ ('<' \w <-[\>]>+ '>') /\n$0/;
#	$json;
    } else {
	$json;
    }
}


sub edit($file) is export {
    my $mtime = $file.IO.modified;
    shell (%*ENV<EDITOR> || 'emacs') ~ ' ' ~ $file;
    $mtime != $file.IO.modified;
}


sub display($text is copy) is export {
    $text = $text.chomp;
    return unless $text;

    my $stamp = config.attr<properties><stamp> ?? colored(now.DateTime.Str, 'yellow') !! '';

    if $SAVE_FILE {
	      spurt $SAVE_FILE, ($text, $stamp).grep(/./).join("\n") ~ "\n", append => $SAVE_APPEND;
	      $SAVE_FILE = '';
	      return;
    }

    if config.attr<properties><page> && q:x/tput lines/.chomp.Int < $text.lines {
        page $text;
        say $stamp;
    } else {
        say ($text, $stamp).grep(/./).join("\n");
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

	      my @binder;
	      @binder[0] = %hash;
        for $k.split('.').kv -> $ix, $t {
	          if $t ~~ /^ \d+ $/ {
	              @binder[$ix + 1] := @binder[$ix][$t];       
	          } else {
	              @binder[$ix + 1] := @binder[$ix]{$t};
	          }
	      }
	      @binder[*-1] = $v;
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

    $out ~~ s:g/'(' [ ':' (<-[|]>+) '|' || <-[)]>+ '|:' (<-[|)]>+) ] .*?  ')'/{$0 ?? $0.Str !! $1.Str}/;

    $out ~~ s:g/'(' (<-[)]>+ '|' <-[)]>+) ')' /{select_from($0.Str)}/;
    $out ~~ s:g/'(string)'/{random_hex(7)}/;
    $out ~~ s:g/'(date)' /{random_date()}/;

    $out;
}


sub interpolate_help is export {
    q:to/END/;
    # Stub interpolation
    #
    #  Lines starting with # are comments and will be removed
    #
    #   {n}       -> The number of the record counting from 1 (eg stub.3 will yield 1, 2 and 3)
    #   {h}       -> A random hex value of 7 chars
    #   {h#}      -> A random hex value of # chars
    #   s:(..|..) -> Randomly select from a list
    #   h:(...)   -> A random hex value of 7 chars
    #   h#:(...)  -> A random hex value of # chars
    #   d:(...)   -> A random date
    #   (..|:..)  -> Select the item following : from a list
    #   (..|..)   -> Same as s:(..|..)
    #   (string)  -> A random hex value of 7 chars
    #   (date)    -> A random date
    #
    END
}


sub remove_comments($text) is export {
    $text.subst(/^^ \s*? '#' .*? \n/, '', :g);
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
