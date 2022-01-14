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
my constant   SCHEMAS_URI        = '/pas/schemas';
my constant   ENUMS_URI          = '/pas/enumerations';
my constant   OLD_ENUMS_URI      = '/config/enumerations';
our constant  USER_URI           = '/users/current-user';
our constant  SEARCH_URI         = '/search';
our constant  SEARCH_RECORDS_URI = '/search/records';
my constant   LOGOUT_URI         = '/logout';

my $SCHEMAS;
my $SCHEMAS_PARSED;
my $ENUMS;
my @LAST_URIS = [];
my @ENDPOINTS = [];
my @TAB_TARGETS;
my @HISTORY_MODELS;

my @SCHEDULES = [];

sub last_uris(@uris = ()) is export { @LAST_URIS = @uris if @uris; @LAST_URIS }
sub tab_targets is export { @TAB_TARGETS }
#sub tab_targets is export { |last_uris, |Command.actions, |@TAB_TARGETS }

sub schedules is export { @SCHEDULES }
sub clean_schedules is export { @SCHEDULES .= grep({none $_<command>.done}) }

my Pas::Store $STORE;
sub store is export { $STORE ||= Pas::Store.new(:dir(%*ENV<HOME> ~ '/.pas')) }

my Config $CFG;
sub config is export { $CFG ||= Config.new(:store(store)) }

my Pas::Logger $LOGGER;
sub logger is export { $LOGGER ||= Pas::Logger.new(:config(config)); }

my Pas::ASClient $CLIENT;
sub client is export { $CLIENT ||= Pas::ASClient.new(:config(config), :log(logger)) }

my ThreadPoolScheduler $SCHEDULER;
sub scheduler is export { $SCHEDULER ||= ThreadPoolScheduler.new }


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


sub pretty($json is copy, Bool :$mark_diff, Str :$select) is export {
    return $json if config.attr<properties><compact>;

    if $json ~~ /^<[\{\[]>/ {
	      JSONPretty::prettify($json, :indent(config.attr<properties><indent>), :mark_diff($mark_diff), :select($select));
    } elsif $json ~~ /^<[\<]>/ {
	      XMLPretty::prettify($json, config.attr<properties><indent>);
    } else {
	      $json;
    }
}


sub edit($file) is export {
    my $mtime = $file.IO.e ?? $file.IO.modified !! 0;
    shell (%*ENV<EDITOR> || 'emacs') ~ ' ' ~ $file;
    $mtime != $file.IO.modified;
}


sub page($text) is export {
    save_tmp($text);
    shell (%*ENV<PAGER> || 'less -R') ~ ' ' ~ tmp_file;
}


sub ansi(Str $s, Str $ansi_fmt) is export {
    if config.attr<properties><color> {
        colored($s, $ansi_fmt);
    } else {
        $s;
    }
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

    $out ~~ s:g/'(string)'/{random_hex(7)}/;
    $out ~~ s:g/'(date)' /{random_date()}/;
    $out ~~ s:g/'"(boolean)"' /{random_truth()}/;

    $out ~~ s:g/'(' (<-[)]>+ ('|' <-[)]>+)?) ')' /{select_from($0.Str)}/;

    $out ~~ s:g/'/:id'/\/1/;

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
    #   (boolean) -> A random true or false
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


sub random_truth {
    crypt_random_uniform(2) == 1 ?? 'true' !! 'false';
}


sub extract_uris($text) is export {
    $text ~~ m:g/ '"' ( '/' <-[\\ \s "]>+ )  '"'  /;
    @LAST_URIS = ($/.map: { $_[0].Str }).sort.unique;
    $text;
}


sub extract_from_schema($text) is export {
    $text ~~ m:g/ 'JSONModel(:' ( <-[ \) ]>+ ) /;
    @LAST_URIS = (($/.map: { $_[0].Str }).sort.unique).map: { 'schemas ' ~ $_ };
    $text ~~ m:g/ '"dynamic_enum"' \s* ':' \s* '"' ( <-[ \" ]>+ ) /;
    @LAST_URIS.append((($/.map: { $_[0].Str }).sort.unique).map: { 'enums ' ~ $_ });
    $text;
}


sub history_models(Bool :$force) is export {
    return @HISTORY_MODELS if @HISTORY_MODELS && !$force;

    if load_endpoints.grep('/history') {
        @HISTORY_MODELS = |(from-json client.get('/history/models')).map({ $_ ~~ s:g/(<[A..Z]>)/{'_' ~ $0.Str.lc}/; $_.substr(1)});
    }

    @HISTORY_MODELS;
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
    # @TAB_TARGETS = |@ENDPOINTS, |Command.actions;
    @ENDPOINTS;
}


sub schemas(Bool :$reload, Str :$name) is export {
     if $reload || !$SCHEMAS {
	       my $schemas = client.get(SCHEMAS_URI);
	       $SCHEMAS = pretty $schemas;
	       $SCHEMAS_PARSED = from-json $schemas;
     }

     if $name {
         if ($SCHEMAS_PARSED{$name}) {
             extract_from_schema(to-json $SCHEMAS_PARSED{$name});
	           $SCHEMAS_PARSED{$name};
         } else {
             my @sch = $SCHEMAS_PARSED.keys.grep(/$name/).sort.Array;
             @LAST_URIS = @sch.map: { 'schemas ' ~ $_ } if @sch;
             @sch;
         }
     } else {
	       $SCHEMAS_PARSED.keys.sort.Array;
     }
}


sub enums(Bool :$reload, Str :$name) is export {
    if $reload || !$ENUMS {
        $ENUMS = from-json(client.get(load_endpoints.grep(ENUMS_URI) ?? ENUMS_URI !! OLD_ENUMS_URI));
    }

    my @enums = $name ?? $ENUMS.grep: { $_<name> ~~ /$name/ } !! $ENUMS.Array;
    last_uris((@enums.map: { 'enums ' ~ $_<name> }).Array.append(@enums.map: { $_<uri> }));
    @enums;
}


sub tmp_file is export {
    store.path(TMP_FILE);
}


sub save_tmp($data) is export {
    store.save(TMP_FILE, $data);
}


sub visible_length($string is copy) is export {
    $string ~~ s:g/\e.+?\#//;
    $string ~~ s:g/\e.+?m//;
    $string.chars;
}


my Int $TERM_COLS;
sub term_cols is export {
    $TERM_COLS //= q:x/tput cols/.chomp.Int;

    # return $TERM_COLS if $TERM_COLS;

    # my $proc = run 'tput', 'cols', :out;
    # $TERM_COLS = $proc.out.slurp.chomp.Int: :close;
}


my Int $TERM_LINES;
sub term_lines is export {
    $TERM_LINES //= q:x/tput lines/.chomp.Int;
}


sub endpoint_for_uri($uri) is export {
        my @u = $uri.split('/');
        my @maybe = [];
        my @probably = load_endpoints.grep: {
            my $endpoint = $_;
            my $out = True;
            my $maybe = True;
            my @e = .split('/');
            if @e.elems == @u.elems {
		            for zip @u, @e -> ($u, $e) {
	       	          $out = False if $e !~~ /^ ':' / && $e ne $u;
                    if $e ~~ /^ ':' / && $e ne $u && $u !~~ /^ \d+ $/ {
	       	              $out = False;
                    }
                    if $e !~~ /^ ':' / && $u !~~ /^ ':' / && $e ne $u {
                        $maybe = False;
                    }
		            }
                @maybe.push($endpoint) if $maybe;
            } else {
                $out = False;
            }

            $out;
        };

        @probably ?? @probably.first !! @maybe.first
}
