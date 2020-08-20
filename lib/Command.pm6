use Config;
use Pas::ASClient;
use Pas::Help;
use Functions;
use Navigation;

use Linenoise;
use Terminal::ANSIColor;
use JSON::Tiny;

class Command {
    has     $.client;
    has Str $.line is rw;
    has Str $.uri is rw;
    has Str $.action is rw;
    has Str $.qualifier is rw;
    has Str $.postfile is rw;
    has Str $.savefile is rw;
    has Bool $.saveappend is rw;
    has Str $.first is rw;
    has Str @.args is rw;
    has Num $.delay is rw;
    has Int $.times is rw;
    has Int $.timesrun;
    has Bool $.cancelled;


    my constant ACTIONS = <show update create edit stub post delete
                           search nav login logout script schedules
                           endpoints schemas config groups
                           session user who asam
                           history last set ls help comment quit>;

    method actions { ACTIONS }


    my constant ALIAS = {
        p => 'page',
        r => 'resolve[]',
        t => 'type[]',
        u => 'uri[]'
    }

    method alias($k) {
        ALIAS{$k} || $k;
    }


    grammar Grammar {
        token TOP           { <.ws> [ <command> | <comment> ] <.ws> }

        rule  command       { [ <uricmd> | <actioncmd> ] <redirect>? <schedule>? }

        rule  uricmd        { <uri> <pairlist> <action>? <postfile>? }
        rule  actioncmd     { <action> <arglist> }

        token comment       { '#' .* }

        token uri           { '/' <[\/\w]>* }
        rule  pairlist      { <pairitem>* }
        rule  pairitem      { <pair> }
        token pair          { <key=.refpath> '=' <value> }
        token refpath       { <[\w\.\d\[\]]>+ }
        token action        { <arg> <qualifier>? }
        token qualifier     { '.' <arg> }
        rule  arglist       { <argitem>* }
        token argitem       { [ <arg> | <singlequoted> | <doublequoted> ] }
        token arg           { <[\w\d]>+ }
        token value         { [ <str> | <singlequoted> | <doublequoted> ] }
        token str           { <-['"\\\s]>+ }
        token singlequoted  { "'" ~ "'" (<-[']>*) }
        token doublequoted  { '"' ~ '"' (<-["]>*) }

        rule  postfile      { '<' <file> }
        rule  redirect      { <saveappend> <file> }
        token saveappend    { '>' ** 1..2 }
        token file          { <[\w/\.\-]>+ }

        token schedule      { '@' <delay> <repeats>? }
        token delay         { <[\d\.]>+ | '*' }
        token repeats       { 'x' <times> }
        token times         { [ <[\d]>+ | '*'] }
    }

    class ParseActions {
        has Command $.cmd;

        method TOP($/)        { $!cmd.line = $/.Str;
                                $!cmd.action ||= 'show';
                                $!cmd.qualifier ||= '';
                                $!cmd.first = $!cmd.uri || ($!cmd.args || ['']).shift; }

        method comment($/)    { $!cmd.action = 'comment' }
        method uri($/)        { $!cmd.uri = $/.Str }
        method pair($/)       { $!cmd.args.push($!cmd.alias($/<key>) ~ '=' ~ ($/<value><str> ||
                                                                               $/<value><singlequoted>[0] ||
                                                                               $/<value><doublequoted>[0]).Str) }

        method action($/)     { $!cmd.action = $/<arg>.Str; }
        method qualifier($/)  { $!cmd.qualifier = $/<arg>.Str; }
        method argitem($/)    { $!cmd.args.push(($<arg> || $<singlequoted>[0] || $<doublequoted>[0]).Str) }

        method postfile($/)   { $!cmd.action = 'post'; $!cmd.postfile = $<file>.Str }
        method redirect($/)   { $!cmd.savefile = $<file>.Str;
                                $!cmd.saveappend = $<saveappend>.Str eq '>>'; }

        method schedule($/)   { $!cmd.times = 1 unless $/<repeats>; }
        method delay($/)      { $!cmd.delay = $/.Str ~~ '*' ?? 0.01.Num !! $/.Num; }
        method repeats($/)    { $!cmd.times = $<times>.Str ~~ '*' ?? 0 !! $<times>.Int; }
    }


    method ran {
        $!timesrun += 1;
    }

    method cancel {
        $!cancelled = True;
    }

    method done {
        $!cancelled || $!times && $!times - $!timesrun == 0;
    }

    method state {
        $!cancelled ?? 'Cancelled' !! self.done ?? 'Complete' !! 'Running';
    }


    my @SPOOL = [];
    sub unspool {
        while (my $unspooled = @SPOOL.shift) {
            $unspooled.head.output($unspooled.tail, :spooled);
        }
    }


    method run(:$spool is copy) {
        $spool &&= !$!savefile;
        $spool || unspool;
        unless self.done {
            my $output = self."{self.action}"();
            if $spool {
                @SPOOL.push((self, $output));
            } else {
                self.output($output);
            }
            self.ran;
        }
    }


    method output($text is copy, :$spooled) {
        $text = $text.chomp;
        return unless $text;

        my $stamp = config.attr<properties><stamp> ?? colored(now.DateTime.Str, 'yellow') !! '';

        if $!savefile {
	          spurt($!savefile, ($text, $stamp).grep(/./).join("\n") ~ "\n", append => $!saveappend) unless $!savefile eq 'null';
	          return;
        }

        if !$spooled && config.attr<properties><page> && q:x/tput lines/.chomp.Int < $text.lines {
            page $text;
            say $stamp;
        } else {
            say ($text, $stamp).grep(/./).join("\n");
        }
    }


    submethod BUILD(:$line) {
        $!times //= 1;
        $!timesrun = 0;
        if $line.trim {
            Grammar.parse($line, :actions(ParseActions.new(cmd => self)));
            logger.blurt(self.gist);
            if self.action {
                if ACTIONS.grep: self.action {
                    if self.delay {
                        # rakudo seems to treat :times=1 as infinity, no :times as 1
                        # i'm using 0 (zero) to indicate infinity
                        # hence the following nonsense
                        if self.times == 1 {
                            schedules.push({command => self,
                                            status => scheduler.cue({self.run(:spool)},
                                                                    :in(self.delay))});
                        } else {
                            schedules.push({command => self,
                                            status => scheduler.cue({self.run(:spool)},
                                                                    :in(self.delay),
                                                                    :every(self.delay),
                                                                    :times(self.times || 1))});
                        }
                    } else {
                        self.run;
                    }
                } else {
                    say "Unknown action: " ~ self.action;
                }
            } else {
                say 'What?';
            }
        } else {
            unspool;            
        }
    }


    # action methods

    method comment {
        # no op
    }


    method show {
        pretty extract_uris client.get($!uri, @!args);
    }


    method update {
        if ($!qualifier eq 'no_get') {
            pretty extract_uris client.post($!uri, @!args, 'nothing');
        } else {
            my $json = client.get($!uri);
            if (from-json($json)<error>) {
                pretty $json;
            } else {
              pretty extract_uris client.post($!uri, @!args, modify_json($json, @!args));
            }
        }
    }


    method create {
        pretty extract_uris client.post($!uri, @!args, modify_json('{}', @!args));
    }


    method edit {
        if ($!qualifier eq 'no_get') {
            save_tmp('');
        } else {
            save_tmp(pretty extract_uris client.get($!uri)) unless $!qualifier eq 'last';
        }
        edit(tmp_file) ?? pretty extract_uris client.post($!uri, @!args, slurp(tmp_file)) !! 'No changes to post.';
    }


    method stub {
        my $puri = $!uri;
        $puri ~~ s:g/\/repositories\/\d+/\/repositories\/:repo_id/;
        $puri ~~ s:g/\d+/:id/;
        my $e = from-json client.get(ENDPOINTS_URI, ['uri=' ~ $puri, 'method=post']);
        return "Couldn't find endpoint definition" if @($e).elems == 0;

        my $model;
        for $e.first<params>.List {
            $model = $_[1];
            last if $model ~~ s/'JSONModel(:' (\w+) ')'/$0/;
        }

        save_tmp(interpolate_help() ~ pretty(client.get('/stub/' ~ $model, @!args)));

        my Int $times = (so $!qualifier.Int) ?? $!qualifier.Int !! 1;
        if edit(tmp_file) {
            my $out = '';
            my $json = slurp(tmp_file);
            for ^$times -> $c {
                $out ~= $c+1 ~ ' ' ~
                pretty extract_uris client.post($!uri,
                                                @!args,
                                                interpolate(remove_comments($json), $c+1))
            }
            $out;
        } else {
            'No changes to post.';
        }
    }


    method post {
        if $!postfile.IO.e {
            pretty extract_uris client.post($!uri, @!args, slurp($!postfile));
        } else {
            'No file to post: ' ~ $!postfile;
        }
    }


    method delete {
        pretty extract_uris client.delete($!uri);
    }


    method search {
        if $!first ~~ /^<[./]>/ { # a uri
            my $results = from-json client.get(SEARCH_RECORDS_URI, ['uri[]=' ~ $!first]);
            if $results<total_hits> == 1 {
                my $record = $results<results>[0];
                $record<json> = from-json $record<json>;
                pretty extract_uris to-json $record;
            } else {
                'No record in search index for ' ~ $!first;
            }
        } else {
            my $page = @!args.tail || '1';
            @!args.push("q=$!first");
            @!args.push("page=$page");
            my $results = client.get(SEARCH_URI, @!args);
            if $!qualifier ~~ /^ 'p'/ { # parse
                my $parsed = from-json $results;
                $parsed<results>.map: { $_<json> = from-json $_<json>; }
                pretty extract_uris to-json $parsed;
            } else {
                pretty extract_uris $results;
            }
        }
    }


    method nav {
        Navigation.new(uri =>$!uri, args =>@!args, line => $!line).start;
    }

    
    method login {
        config.prompt if $!qualifier eq 'prompt';
        client.login;
    }


    method logout {
        pretty client.logout;
    }
    

    method script {
        if $!first {
            if $!first.IO.e {
                for slurp($!first).lines -> $line {
                    next unless $line;
                    say cmd_prompt() ~ $line;
                    Command.new(:$line);
                }
                'Script complete';
            } else {
                'Script file not found: ' ~ $!first;
            }
        } else {
            'Give a file path like this: script foo.txt';
        }
    }
    

    method session {
        if $!first {
            if $!qualifier eq 'delete' {
                client.delete_session($!first);
            } else {
                my $out = client.switch_to_session($!first);
                load_endpoints(:force);
                $out;
            }
        } else {
            my $last_url = False;
            my $ix = 0;
            my $out = (for config.attr<sessions>.sort -> $pair {
                              my $k = $pair.key;
                              my $v = $pair.value;
                              $ix += 1;
                              my $user_fmt = colored('%-20s', $k eq config.session_key ?? 'bold green' !! 'bold white');
                              my $ix_fmt = colored('%02d', 'cyan');

                              if $v<url> eq $last_url {
                                  sprintf("%-25s  [$ix_fmt]  $user_fmt",
                                          $v<time> ?? DateTime.new($v<time>).local.truncated-to('second') !! '[unauthenticated]',
                                          $ix, $v<user>);
                              } else {
                                  $last_url = $v<url>;
                                  my $version = (from-json client.get('/', :no_session, host => $v<url>, timeout => 1))<archivesSpaceVersion> || 'down';
                                  my $version_fmt = colored('%-20s', $version eq 'down' ?? 'white' !! 'bold white');
                                  sprintf("\n%-25s  [$ix_fmt]  $user_fmt  $version_fmt  %s",
                                          $v<time> ?? DateTime.new($v<time>).local.truncated-to('second') !! '[unauthenticated]',
                                          $ix, $v<user>, $version, $v<url>);
                              }
                          }).join("\n") ~ "\n";
            $out;
        }
    }


    method user {
        pretty extract_uris client.get(USER_URI);
    }


    method who {
        from-json(client.get(USER_URI))<name>;
    }

    method history {
        my @lines = slurp(store.path(HISTORY_FILE)).split("\n").grep(/\S/);
        if $!first {
            @lines.tail($!first).join("\n");
        } else {
            @lines.join("\n");
        }
    }

    method endpoints {
        load_endpoints.join("\n");
    }


    method schemas {
        schemas(:reload($!qualifier eq 'reload'), :name($!first));
    }
    

    method config {
        config.json;
    }


    method last {
        slurp tmp_file;
    }
    

    method set {
        my %prop := config.attr<properties>;
        unless $!qualifier {
            if $!first eq 'defaults' {
                config.apply_property_defaults(:force);
                config.save;
                return 'Properties reset to default values';
            } else {
                return (for %prop.kv -> $k, $v {
                               my $out = $v;
                               $out = colored('on', 'bold green') if $out.WHAT ~~ Bool && $out;
                               $out = colored('off', 'bold red') if $out.WHAT ~~ Bool && !$out;
                               $out = colored($out.Str, 'bold white') if $out.WHAT ~~ Int;
                               sprintf("  %-10s %s", $k, $out);
                           }).join("\n");
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
                    $!qualifier ~ colored(' off', 'bold red');
                } elsif $!first ~~ /./ {
                    %prop{$!qualifier} = True;
                    config.save;
                    $!qualifier ~ colored(' on', 'bold green');
                } else {
                    $!qualifier ~ (%prop{$!qualifier} ?? colored(' on', 'bold green') !! colored(' off', 'bold red'));
                }
            }
            when Int {
                if so $!first.Int {
                    %prop{$!qualifier} = $!first.Int;
                    config.save;
                    $!qualifier ~ ' ' ~ colored(%prop{$!qualifier}.Str, 'bold white');
                } elsif $!first ~~ /./ {
                    $!qualifier ~ ' must be a number';
                } else {
                    $!qualifier ~ ' ' ~ colored(%prop{$!qualifier}.Str, 'bold white');
                }
            }
        }
    }


    method ls {
        qq:x/$!line/.trim;
    }


    method asam {
        my $asam = from-json client.get('/plugins/activity_monitor', @!args);

        if $asam<error> {
            return pretty to-json $asam;
        }

        my $longest_name = max($asam<statuses>.keys>>.chars);
        my $days = 60*60*24;
        my $hours = 60*60;
        my $mins = 60;
        my $out = '';
        my $indent = $!first ?? '' !! '  ';
        for $asam<groups>.keys.sort -> $group {
            my $statuses = $asam<groups>{$group};
            $out ~= "$group\n" unless $!first;
            for @$statuses -> $name {
                my $status = $asam<statuses>{$name};
                my $name_fmt = colored("%-{$longest_name}s", 'bold white');

                my $age = $status<age>;

                given $age {
                    when $_ > $days {
                        $age = ($age / $days).round ~ 'd';
                    }
                    when $_ > $hours {
                        $age = ($age / $hours).round ~ 'h';
                    }
                    when $_ > $mins {
                        $age = ($age / $mins).round ~ 'm';
                    }
                    default {
                        $age = $age ~ 's';
                    }
                }

                $out ~= sprintf("{$indent}$name_fmt  %s  %s\n",
                                $name,
                                colored($status<message>, ($status<status> ~~ 'good' ?? 'bold green' !!
                                                           ($status<status> ~~ 'busy' ?? 'bold blue' !!
                                                            ($status<status> ~~ 'no' ?? 'white' !! 'bold red')))),
                                colored($age, 'cyan')) if !$!first || $!first eq $name;
            }
        }

        $out
    }


    method schedules {

        sub render-schedule($ix) {
            my $s = schedules[$ix];
            return '' unless $s;
            my $ix_fmt = colored("%02d", 'cyan');
            my $status_fmt = colored("%-10s", 'bold white');
            my $runs_fmt = colored("%d/%s", 'magenta');
            sprintf("[$ix_fmt]  $status_fmt  %s  ($runs_fmt)\n",
                    $ix+1,
                    $s<command>.state,
                    $s<command>.line,
                    $s<command>.timesrun,
                    $s<command>.times || '*');
        }

        if $!first {
            unless $!first.Int {
                return 'Argument must be an integer';
            }
            my $ix = $!first.Int - 1;
            unless schedules[$ix] {
                return 'Argument must reference an existing schedule';
            }

            if $!qualifier eq 'cancel' {
                if schedules[$ix]<command>.cancelled {
                    "Schedule {$ix + 1} is already cancelled";
                } elsif schedules[$ix]<command>.done {
                    "Schedule {$ix + 1} is already done";
                } else {
                    schedules[$ix]<status>.cancel;
                    schedules[$ix]<command>.cancel;
                    "Schedule {$ix + 1} cancelled";
                }
            } else {
                render-schedule($ix);
            }
        } else {
            if $!qualifier eq 'clean' {
                clean_schedules;
            }
            gather {
                for (0..schedules.elems - 1) -> $ix {
                    take render-schedule($ix);
                }
            }.join || 'No current schedules';
        }
    }


    method groups {
        if $!first {
            my $groups = from-json(extract_uris client.get("/repositories/$!first/groups"));
            $groups.map({ $_<group_code> ~ ' ' ~ $_<uri> }).join("\n");
        } else {
            "Give a repo id like this:\n> groups 2"
        }
    }


    method help {
        if $!first {
            if @!args > 0 && @!args[0].starts-with('w') {
                if edit(store.path(Pas::Help.new(:store(store)).file($!first))) {
                    "Help saved.";
                } else {
                    'No changes to save.';
                }
            } else {
                Pas::Help.new(:store(store)).topic($!first);
            }
        } else {
            shell_help;
        }
    }


    method quit {
        say 'Goodbye';    
        exit;
    }
}


sub shell_help {
    q:heredoc/END/;

    pas shell help

    uri pairs* action? [ < file ] [ > file ] [ @d[xt] ]
    action args* [ > file ]

    uri actions:
      show      show (default)
      update    update with the pairs
       .no_get  post a nonce body
      create    create using the pairs
      edit      edit to update
       .last    using last edited record
       .no_get  using an empty file
      stub      create from an edited stub
       .[n]     post n times
      post      post a file (default if last arg is a file)
      search    show search index document

    other actions:
      login     force a login
       .prompt  prompt for details
      user      show the current user
      session   show sessions or switch to a session
       .delete  delete a session
      schedules show current schedules
        .cancel cancel numbered schedule
        .clean  remove all completed schedules
        [n]     show or cancel numbered schedule
      script    run a pas script file
      endpoints show the available endpoints
       .reload  force a reload
      schemas   show all record schemas
       .reload  force a reload
       [name]   show a named record schema
      search    perform a search (page defaults to 1)
       .parse   parse the 'json' property
       q        the query string
       [n]      page number (defaults to 1)
      config    show pas config
      last      show the last saved temp file
      set       show pas properties
       .[prop]  show or set prop
      history   show command history
       [n]      show the last n commands 
      help      this
      quit      exit pas (^d works too)

      < file    post file to uri
      > file    redirect output to file instead of displaying
                if file is 'null' then don't display or save

      @d[xt]      schedule command to run t times (default 1) every d seconds

    Say 'help [action]' for detailed help. ... well, not yet

    Use the <tab> key to cycle through completions for uris or actions.

    Command history and standard keybindings.
END
}
