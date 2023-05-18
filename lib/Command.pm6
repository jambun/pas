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
    has Channel $.timesrunlock;
    has Str $.output is rw;
    has Bool $.cancelled;


    my constant ACTIONS = <show update create edit stub revisions post delete import
                           search nav login logout script schedules
                           endpoints schemas config groups users enums
                           session who asam doc assb find
                           history last set ls help comment quit>;

    my constant QUALIFIED_ACTIONS = <<update.no_get edit.no_get edit.last revisions.restore
                                      stub.n search.parse search.public login.prompt
                                      session.delete users.create users.me users.pass
                                      endpoints.reload doc.get doc.post doc.delete
                                      assb.keys assb.install assb.plugins assb.catalog
                                      schemas.reload schemas.property
                                      enums.add enums.remove enums.tr enums.reload
                                      {Config.new.prop_defaults.keys.map({'set.' ~ $_})}
                                      schedules.cancel schedules.clean asam.reset history.n
                                      groups.add groups.remove groups.removeall
                                      help.list help.write>>;

    method actions { ACTIONS }
    method qualified_actions { QUALIFIED_ACTIONS }


    method contextual_completions(Str $line is copy) {
        my @out;

        sub build_cc($line, $prefix, @list) {
            @out.append(@list.grep(/^ $prefix/).map: { my $c = $_ ~~ /\s/ ?? "'$_'" !! $_; $line ~ $c});
        }

        build_cc($line, $1.Str, search_models) if $line ~~ s/('find' \s+ .* '=') (\w*) $/$0/;

        build_cc($line, $1.Str, history_models) if $line ~~ s/('revisions' \s+ .* '=') (\w*) $/$0/;
        build_cc($line, $1.Str, history_makers) if $line ~~ s/('revisions' \s+ .* ';') (\w*) $/$0/;

        build_cc($line, $1.Str, repo_codes) if $line ~~ s/^ ('groups' ( '.' \S+ )? \s+) (\w*) $/$0/;
        build_cc($line, $1.Str, system_users) if $line ~~ s/^ ('groups.add' \s+ \w+ \s+ \d+ \s+) (\w*) $/$0/;
        build_cc($line, $1.Str, system_users) if $line ~~ s/^ ('groups.remove' \s+ \w+ \s+ \d+ \s+) (\w*) $/$0/;

        build_cc($line, $1.Str, repo_codes) if $line ~~ s/^ ('import' \s+) (\w*) $/$0/;
        build_cc($line, $1.Str, import_types($0[0].Str)) if $line ~~ s/('import' \s+ (\S+) \s+) (\w*) $/$0/;

        build_cc($line, '', <on off>) if $line ~~ /^ ('set.' \w+ \s+) $/;

        build_cc($line, '', <list request install remove switch>) if $line ~~ /^ ('assb.keys' \s+) $/;
        build_cc($line, $1.Str, assb_cat_names) if $line ~~ s/^ ('assb.install' \s+) (\w*) $/$0/;

        @out;
    }


    my constant ALIAS = {
        p => 'page',
        r => 'resolve[]',
        t => 'type[]',
        u => 'uri[]',
        e => 'expand[]'
    }

    method alias($k) {
        ALIAS{$k} || $k;
    }


    grammar Grammar {
        token TOP           { <.ws> [ <command> | <comment> ] <.ws> }

        rule  command       { [ <uricmd> | <actioncmd> ] <redirect>? <schedule>? }

        rule  uricmd        { <uri> <pairlist> <action>? <arglist> <postfile>? }
        rule  actioncmd     { <action> <arglist> }

        token comment       { '#' .* }

        token uri           { '/' <[\/\-_\w\:\.]>* }
        rule  pairlist      { <pairitem>* }
        rule  pairitem      { <pair> }
        token pair          { <key=.refpath> '=' <value> }
        token refpath       { <[\w\.\d\[\]]>+ }
        token action        { <keyword> <qualifier>? }
        token qualifier     { '.' <keyword> }
        token keyword       { <[\w\d\_]>+ }
        rule  arglist       { <argitem>* }
        rule  argitem       { <argvalue> }
        token argvalue      { [ <arg> | <singlequoted> | <doublequoted> ] }
        token arg           { <[\w\d\=\-\_\/\+\,\;\.]> \S* }
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

        method action($/)     { $!cmd.action = $/<keyword>.Str; }
        method qualifier($/)  { $!cmd.qualifier = $/<keyword>.Str; }
        method argvalue($/)   { $!cmd.args.push(($<arg> || $<singlequoted>[0] || $<doublequoted>[0]).Str) }

        method postfile($/)   { $!cmd.action = 'post'; $!cmd.postfile = $<file>.Str }
        method redirect($/)   { $!cmd.savefile = $<file>.Str;
                                $!cmd.saveappend = $<saveappend>.Str eq '>>'; }

        method schedule($/)   { $!cmd.times = 1 unless $/<repeats>; }
        method delay($/)      { $!cmd.delay = $/.Str ~~ '*' ?? 0.01.Num !! $/.Num; }
        method repeats($/)    { $!cmd.times = $<times>.Str ~~ '*' ?? 0 !! $<times>.Int; }
    }


    method ran {
        $!timesrunlock.receive;
        $!timesrun += 1;
        $!timesrunlock.send(<lock>);
    }

    method cancel {
        $!cancelled = True;
    }

    method done {
        $!cancelled || $!times && $!times - $!timesrun < 1;
    }

    method state {
        $!cancelled ?? 'Cancelled' !! self.done ?? 'Complete' !! 'Running';
    }


    my Channel $SPOOL = Channel.new;
    sub unspool {
        while $SPOOL.poll -> $cmd { $cmd.print }
    }


    method run(:$spool is copy) {
        $spool &&= config.attr<properties><spool> && !$!savefile;
        $spool || unspool;
        unless self.done {
            self.action = 'doc' if self.uri && self.uri ~~ /\:/;

            my $out = self."{self.action}"();

            if ($out ~~ Buf) {
                if (!$!savefile) {
                    say 'Binary response with content type: ' ~ client.last_response_header<Content-Type>[0];
                    print 'Enter file name (or return to discard): ';
                    $!savefile = get.chomp;
                    return unless $!savefile;
                }
                say "Saved to: " ~ ($!savefile ~~ /^ '/' / ?? $!savefile !! $*CWD ~ '/' ~ $!savefile);
	              spurt($!savefile, $out, append => $!saveappend) unless $!savefile eq 'null';
                return;
            } elsif (!$out.defined) {
                $out = '';
            }

            $!output = $out.Str;
            if $spool {
                $SPOOL.send(self);
            } else {
                self.print;
            }
            self.ran;
        }
    }


    method print(:$spooled) {
        $!output || say 'No output' && return;

        my $text = $!output.chomp;
        return unless $text;

        my $stamp = config.attr<properties><stamp> ?? ansi(now.DateTime.Str, 'yellow') !! '';

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
        $!timesrunlock = Channel.new;
        $!timesrunlock.send(<lock>);

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
        $puri ~~ s/\/repositories\/(\d+)/\/repositories\/:repo_id/;
        my $repo_id = $0.Str if $0;
        $puri ~~ s:g/\d+/:id/;
        my $e = from-json client.get(ENDPOINTS_URI, ['uri=' ~ $puri, 'method=post']);
        return "Couldn't find endpoint definition" if @($e).elems == 0;

        my $model;
        for $e.first<params>.List {
            $model = $_[1];
            last if $model ~~ s/'JSONModel(:' (\w+) ')'/$0/;
        }

        save_tmp(interpolate_help() ~ pretty(client.get('/stub/' ~ $model, $repo_id ?? (|@!args, "repo_id=$repo_id") !! @!args)));

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


    method import {
        return "You did it wrong!\nDo it like this:\n  > import repo_code import_type files+" unless $!first && @!args > 1;

        my $repo_code = $!first;

        my $repo_id = repo_map($repo_code);
        return "Unknown repository '{$!first}'!" unless $repo_id;

        my $type = @!args.shift;
        return "Unknown import type '{$type}' for repository '{$repo_code}'!" unless import_types($repo_code).grep($type);

        my @files = @!args;
        my %parts;

        my @headers =
            'Content-Type' => 'text/plain',
            'Content-Transfer-Encoding' => 'binary';

        for 0..^@files -> $i {
            my $file = @files[$i];
            return "Can't find file: $file" unless $file.IO.e;
            %parts{"files[{$i}]"} = [$file, $file.IO.basename, |@headers];
        }

        my $uri = "/repositories/{$repo_id}/jobs_with_files";
        my $import_job = import_job($type, @files);

        %parts{'job'} = $import_job;

        print "Uri: {$uri}\nJob:\n{$import_job}\nReady to import? (y/N) ";
        my $resp = get;

        if $resp eq 'y' {
            pretty extract_uris client.multi_part($uri, [], %parts);
        } else {
            'Chicken';
        }
    }


    method revisions {
        # /uri revisions [rev[/[/][diff]]] | ( [+cnt] ( [;user] [-date] | [,rev] ) )
        # revisions ( [+cnt] [=model] [;user] [-date] )
        # /uri revisions.restore rev

        return unless check_endpoint('/history', 'Revision histories unavailable. Install as_history plugin.');

        my $huri = '/history';

        if $!uri {
            my $record = from-json client.get($!uri);
            if $record<history> {
                $huri = $record<history><ref>;
            } else {
                return 'No revision history for ' ~ $!uri;
            }
        }

        my @args;
        my Int $revision;
        my Int $diff;
        my Bool $inline;

        @!args.push($!first) unless $!uri;

        for @!args -> $a {
            if $a ~~ /^ (\d+) (\/ (\/)? ( \d* ) )? $/ {
                return 'Makes no sense to provide a revision without a uri' unless $!uri;
                $revision = $0.Int;
                $huri ~= "/$revision";
                if $1 {
                    $diff = $1[1].Int || ($revision.Int - 1);
                    @args.push("diff=$diff");
                    $inline = $1[0].so;
                }
            } elsif $a ~~ /^ \+ ( \d+ ) $/ {
                @args.push("limit={$0.Str}");
            } elsif $a ~~ /^ \; ( \S+ ) $/ {
                @args.push("user={$0.Str}");
            } elsif $a ~~ /^ \- ( \S+ ) $/ {
                my $d = $0.Str;
                if $d ~~ /^ (\d+)d $/ {
                    my $days = $0.Int;
                    @args.push('at=' ~ Date.today.earlier(:days($days)).Str);
                } else {
                  @args.push("at={$d}");
                }
            } elsif $a ~~ /^ \, ( \d+ ) $/ {
                return 'Makes no sense to provide a start revision' if $revision;
                $huri ~= $0.Str;
            } elsif $a ~~ /^ \= ( \S+ ) $/ {
                return 'Makes no sense to provide a model' if $!uri;
                $huri ~= "/{$0.Str}";
            }
        }

        @args.push('mode=full');
        @args.push('array=true') unless $revision;

        my $history = client.get($huri, @args);


        sub render_revisions($revs) {
            "\n" ~
            ($revs.map: -> $r {
                    next unless $r<last_modified_by>; # edge case - the global repo is created by nobody apparently
                    ansi($r<model>, 'bold') ~ ' / ' ~ ansi($r<record_id>.Str, 'bold') ~ ' .v' ~
                    ansi($r<revision>.Str, 'bold magenta') ~
                    ' :: ' ~ ansi($r<short_label>, 'yellow') ~ "\n" ~
                    ansi($r<last_modified_by>, 'cyan') ~ ' at ' ~ $r<user_mtime>;
                }).join("\n\n") ~ "\n\n";
        }


        if $revision {
            if $!qualifier eq 'restore' {
                return pretty client.post($huri ~ '/restore', [], 'nothing')
            }

            my $h = from-json $history;
            my $out = render_revisions($h<data>.values);
            if $diff {
                $out ~= 'Diff with revision .v' ~ ansi($diff.Str, 'bold magenta') ~ ":\n\n";
                $out ~= pretty($history, :mark_diff, :select('inline_diff'), :$inline);
            } else {
                $out ~= pretty($history, :select('json'));
            }
            $out;
        } else {
            my $h = from-json $history;
            my $r = $h<versions>;
            if $r {
                if $r.WHAT ~~ Array {
                    $r = $r.map: { $_<_resolved> };
                } else {
                    $r = ($r.values.sort: { $_<user_mtime> }).reverse;
                }
                last_uris(@$r.map: {$_<uri> ~ ' revisions ' ~ $_<revision>});
                render_revisions(@$r);
            } else {
                'No matching revisions.'
            }
        }
    }

    method find {
        my @search_args;
        my @query;
        my $page = '1';

        for $!first, |@!args -> $arg {
            if $arg ~~ / ^ '=' / {
                @search_args.push('type[]=' ~ $arg.substr(1));
            } elsif $arg ~~ /^ ',' \d+ $ / {
                $page = $arg.substr(1);
            } else {
                @query.push($arg);
            }
        }

        @search_args.push('q=' ~ @query.join(' ')) if @query;
        @search_args.push('page=' ~ $page);

        my $results = client.get(SEARCH_URI, @search_args);
        my $parsed = from-json $results;

        my $out;

        if ($parsed<this_page> > $parsed<last_page>) {
            return "Page out of bounds";
        } else {
            $out = ansi("{$parsed<offset_first>}-{$parsed<offset_last>} of {$parsed<total_hits>}\n", 'bold');
        }

        last_uris($parsed<results>.map: { $_<uri> });

        $parsed<results>.map: { $_<_id> = $_<uri>.split('/')[*-1].Str };

        my $max_type = max($parsed<results>.map({$_<primary_type>})>>.chars);
        my $max_id = max($parsed<results>.map({$_<_id>})>>.chars);
        my $max_ident = max($parsed<results>.map({$_<identifier> || '--'})>>.chars);

        my $type_fmt = ansi("%-{$max_type}s", 'yellow');
        my $id_fmt = ansi("%-{$max_id}d", 'cyan');
        my $ident_fmt = ansi("%-{$max_ident}s", 'bold green');
        my $title_fmt = ansi('%s', 'white');

        $out ~= $parsed<results>.map({
                  sprintf("$type_fmt  $id_fmt  $ident_fmt  $title_fmt",
                          $_<primary_type>,
                          $_<_id>,
                          $_<identifier> || '--',
                          $_<title>);
                }).join("\n");

        $out;
    }

    method search {
        if $!first ~~ /^<[./]>/ { # a uri
            if $!qualifier eq 'public' {
                $!first ~= '#pui';
            }
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
            my $results = client.get(SEARCH_URI, ["q=$!first", "page=$page"]);
            if $!qualifier eq 'parse' {
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
                clear_session_state;
                $out;
            }
        } else {
            my $last_url = False;
            my $ix = 0;
            my $out = (for config.attr<sessions>.sort -> $pair {
                              my $k = $pair.key;
                              my $v = $pair.value;
                              $ix += 1;
                              my $user_fmt = ansi('%-20s', $k eq config.session_key ?? 'bold green' !! 'bold white');
                              my $ix_fmt = ansi('%02d', 'cyan');

                              if $v<url> eq $last_url {
                                  sprintf("%-25s  [$ix_fmt]  $user_fmt",
                                          $v<time> ?? DateTime.new($v<time>).local.truncated-to('second') !! '[unauthenticated]',
                                          $ix, $v<user>);
                              } else {
                                  $last_url = $v<url>;
                                  my ($version, $label) = try {
                                      my $as = (from-json client.get('/', :no_session, host => $v<url>, timeout => 1));
                                      $as<git_archivesSpaceVersion> || $as<archivesSpaceVersion> || 'down',
                                      $as<label> || 'no label'
                                  } // 'error';
                                  my $version_fmt = ansi('%-26s', ($version eq 'down' | 'error') ?? 'white' !! 'bold white');
                                  my $label_fmt = ansi('%-12s', ($label eq 'no label' | 'error') ?? 'white' !! 'bold yellow');
                                  sprintf("\n%-25s  [$ix_fmt]  $user_fmt  $label_fmt  $version_fmt  %s",
                                          $v<time> ?? DateTime.new($v<time>).local.truncated-to('second') !! '[unauthenticated]',
                                          $ix, $v<user>, $label, $version, $v<url>);
                              }
                          }).join("\n") ~ "\n\n";
            $out;
        }
    }


    method users {
        given $!qualifier {
            when <create> {
                if $!first {
                    my $resp = from-json(client.post('/users', ["password=$!first"],
                                                     to-json({username => $!first, name => $!first})));
                    if $resp<error> {
                        pretty to-json $resp;
                    } else {
                        "User '$!first' created";
                    }
                } else {
                    'Give a username to create';
                }
            }
            when <me> {
                pretty extract_uris client.get(USER_URI);
            }
            when <pass> {
                my $username = $!first || config.attr<user>;
                my $user = from-json client.get('/users/byusername/' ~ $username);
                if $user<error> {
                    pretty to-json $user;
                } else {
                    my $pwd = config.prompt_for('pass', 'Enter new password for ' ~ $username, :pass, :no_set);
                    my $pwdchk = config.prompt_for('pass', 'Confirm new password for ' ~ $username, :pass, :no_set);

                    if $pwd eq $pwdchk {
                        my $resp = client.post($user<uri>, ["password=$pwd"], to-json($user));

                        if $resp<error> {
                            pretty to-json $resp;
                        } else {
                            "Password updated for $username";
                        }
                    } else {
                        'Password not confirmed correctly. No changes made.'
                    }
                }
            }
            default {
                pretty extract_uris client.get('/users', ['page=1']);
            }
        }
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
        return unless check_endpoint('/endpoints', 'Endpoints unavailable. Install pas_endpoints plugin.');

        my @ep = load_endpoints(:force($!qualifier eq 'reload'));

        if $!first {
            my $f = $!first;
            my @uris = @ep.grep(/$f/);
            return 'No endpoints match: ' ~ $!first unless @uris;
            last_uris(@uris);
            @uris.join("\n");
        } else {
            @ep.join("\n");
        }
    }


    method doc {
        return unless check_endpoint('/endpoints', 'Endpoint documentation unavailable. Install pas_endpoints plugin.');

        my @u = $!uri.split('/');
        my $endpoint = endpoint_for_uri($!uri);

        if $endpoint {
            my @args = ['uri=' ~ $endpoint];
            @args.push('method=' ~ $!qualifier) if $!qualifier;
            my (@endpoints) = from-json client.get('/endpoints', @args);
            my $out = "\n";
            for @endpoints -> $ep {
                $out ~= ansi($ep{'method'}.join(' ').uc, 'bold green') ~ ' ' ~ ansi($ep{'uri'}, 'bold');
                if $ep{'permissions'}.WHAT ~~ Array && $ep{'permissions'}.elems > 0 {
                    $out ~= '  [' ~ ansi($ep{'permissions'}.join(' '), 'red') ~ ']';
                }
                $out ~= "\n" ~ ansi($ep{'description'}, 'yellow');

                if ($ep{'paginated'}) {
                    $ep{'params'}.push(['page', 'Integer', 'Page number']);
                    $ep{'params'}.push(['id_set', 'Array', 'List of IDs']);
                    $ep{'params'}.push(['all_ids', 'Boolean', 'Return a list of all IDs']);
                }

                $out ~= "\n" ~ ($ep{'params'}.map: {
                                       my @opts = [];
                                       if $_[3] {
                                           @opts.push('body') if $_[3]{'body'};
                                           @opts.push('optional') if $_[3]{'optional'};
                                           @opts.push('default=' ~ $_[3]{'default'}) if !!$_[3].keys.grep('default')
                                       }
                                       my $opts = '';
                                       $_[1] ~~ s/.* 'Boolean' .*/Boolean/;
                                       $opts = '[' ~ ansi(@opts.join(' '), 'green') ~ ']' if @opts.elems > 0;
                                       '  ' ~ (ansi($_[0], 'bold'), $_[1], $opts).join(' ') ~ "\n    " ~ ansi(($_[2] || '[no description]'), 'yellow');
                                   }).join("\n");
                $out ~= '  [no params]' if !$ep{'params'};
                $out ~= "\n\n";
            }
            $out;
        } else {
            "Oh dear. Can't find that endpoint!";
        }
    }


    method schemas {

        sub render_jsonmodel(Str $ref is copy) {
            $ref ~~ s/ 'JSONModel(:' (<-[\)]>+) ')' \s+ (\S+)/{ $1.Str ~ '(' ~ ansi($0.Str, 'bold green') ~ ')'  }/;
            $ref;
        }

        sub render_type($type) {
            ($type.Array.map: { render_jsonmodel($_.WHAT ~~ Hash ?? $_<type> !! $_); }).join(' | ');
        }

        sub render_prop($name, $prop, Int $depth = 1) {
            my $indent = '  ' x $depth;
            my $out = $indent ~ ansi($name, 'bold') ~ ' ';
            my $leader_length;

            if $prop.WHAT ~~ Hash {
                my @traits = [];
                @traits.push(ansi('readonly', 'cyan')) if $prop<readonly>;
                @traits.push(ansi('required', 'red')) if $prop<ifmissing>;
                $out ~= '[' ~ @traits.join(' ') ~ '] ' if @traits;

                $leader_length = visible_length($out);

                if $prop<dynamic_enum> {
                    $out ~= 'enum(' ~  ansi($prop<dynamic_enum>, 'bold yellow') ~ ')';
                } elsif $prop<enum> {
                    $out ~= $prop<type> ~ '(' ~  $prop<enum>.join(', ') ~ ')';
                } elsif $prop<type> eq 'array' {
                    $out ~= 'array of ' ~ render_type($prop<items><type>);
                    if $prop<items><properties> {
                        $out ~= "\n" ~ render_props($prop<items><properties>.keys, $prop<items><properties>, $depth + 1);
                    }
                } else {
                    $out ~= render_type($prop<type>);

                    if $prop<minLength> || $prop<maxLength> {
                        $out ~= '(' ~ ($prop<minLength> || '') ~ '..' ~ ($prop<maxLength> || '') ~ ')';
                    }

                    if $prop<default> {
                        $out ~= '(default=' ~ $prop<default> ~ ')';
                    }

                    if $prop<properties> {
                        $out ~= "\n" ~ render_props($prop<properties>.keys, $prop<properties>, $depth + 1);
                    }
                }
            } else {
               $out ~= $prop;
            }

            $out = wrap_lines($out, $leader_length);
            $out ~= "\n" if $depth == 1;
            $out;
        }

        sub render_props(@keys, %props, Int $depth = 1) {
            my @skip_props = <created_by last_modified_by jsonmodel_type user_mtime system_mtime create_time lock_version>;
            my @top_props = <ref _resolved>;
            my $out = '';

            # FIXME: how about a cunning sort instead?
            for @top_props -> $t {
                $out ~= render_prop($t, %props{$t}, $depth) if %props{$t};
            }

            for @keys -> $k {
                next if @skip_props.grep($k);
                next if @top_props.grep($k);

                $out ~= render_prop($k, %props{$k}, $depth);
            };

            $out.chomp;
        }


        my $schema = schemas(:reload($!qualifier eq 'reload'), :name($!first), :prop($!qualifier eq 'property'));

        return ($schema ?? $schema.join("\n") !! 'No schema matches: ' ~ $!first) if $schema.WHAT ~~ Array;

        my $out = "\n" ~ ansi("JSONModel(:$!first)", 'bold green');
        $out ~= '  ' ~ $schema<uri> if $schema<uri>;
        $out ~= "\n";
        $out ~= render_props($schema<property_list>, $schema<properties>);
        $out ~ "\n";
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
                               $out = ansi('on', 'bold green') if $out.WHAT ~~ Bool && $out;
                               $out = ansi('off', 'bold red') if $out.WHAT ~~ Bool && !$out;
                               $out = ansi($out.Str, 'bold white') if $out.WHAT ~~ Int;
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
                    $!qualifier ~ ansi(' off', 'bold red');
                } elsif $!first ~~ /./ {
                    %prop{$!qualifier} = True;
                    config.save;
                    $!qualifier ~ ansi(' on', 'bold green');
                } else {
                    $!qualifier ~ (%prop{$!qualifier} ?? ansi(' on', 'bold green') !! ansi(' off', 'bold red'));
                }
            }
            when Int {
                if so $!first.Int {
                    %prop{$!qualifier} = $!first.Int;
                    config.save;
                    $!qualifier ~ ' ' ~ ansi(%prop{$!qualifier}.Str, 'bold white');
                } elsif $!first ~~ /./ {
                    $!qualifier ~ ' must be a number';
                } else {
                    $!qualifier ~ ' ' ~ ansi(%prop{$!qualifier}.Str, 'bold white');
                }
            }
        }
    }


    method ls {
        qq:x/$!line/.trim;
    }


    method asam {
        return unless check_endpoint('/plugins/activity_monitor', 'Acitivity monitor unavailable. Install asam plugin.');

        if $!qualifier ~~ <reset> && !$!first.Int {
            return "Give a status number to reset like this:\n  > asam.reset 2";
        }

        my $asam = from-json client.get('/plugins/activity_monitor', @!args);

        if $asam<error> {
            return pretty to-json $asam;
        }

        sub groups {
           $asam<groups>.keys.sort;
        }

        sub statuses {
           groups.map({ |$asam<groups>{$_} });
        }

        my $longest_name = max($asam<statuses>.keys>>.chars);
        my $name_fmt = ansi("%-{$longest_name}s", 'bold white');
        my $n_fmt = ansi("%02d", 'cyan');
        my $days = 60*60*24;
        my $hours = 60*60;
        my $mins = 60;

        sub render-status($n, $name, $status) {
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

            sprintf("  [$n_fmt]  $name_fmt  %s  %s",
                    $n,
                    $name,
                    ansi($status<message>, ($status<status> ~~ 'good' ?? 'bold green' !!
                                               ($status<status> ~~ 'busy' ?? 'bold blue' !!
                                                ($status<status> ~~ 'no' ?? 'white' !! 'bold red')))),
                    ansi($age, 'blue')) if !$!first || $!first.Int || $name.lc.contains($!first.lc);
        }


        if $!first && $!first.Int {
            my $ix = $!first - 1;
            if $!qualifier ~~ <reset> {
                my $resp = from-json client.post('/plugins/system_status',
                                                 ['name=' ~ statuses[$ix],
                                                  'status=no',
                                                  'message=[reset on console]'],
                                                 'nothing');
                if $resp<error> {
                    $resp<error>
                } else {
                    $asam = from-json client.get('/plugins/activity_monitor', @!args);
                    $longest_name = max($asam<statuses>.keys>>.chars);
                }
            }

            render-status($!first, statuses[$!first - 1], $asam<statuses>{statuses[$!first - 1]});
        } else {
            my $n = 1;
            gather {
                for groups() -> $group {
                    my $statuses = $asam<groups>{$group};
                    take $group unless $!first;
                    for @$statuses -> $name {
                        take render-status $n++, $name, $asam<statuses>{$name};
                    }
                }
            }.join("\n");
        }
    }


    method assb {
        return unless check_endpoint('/assb_admin', 'Sail boats unavailable. Install assb plugin.');

        sub render-plugin($p, $max, $pending = False) {
            my $s = max($max - $p<name>.chars + 2, 2);
            '  ' ~ ansi($p<name>, 'bold') ~ (' ' x $s) ~ ansi($p<display_name>, 'yellow') ~ ($pending ?? " [{%$pending<mode>}]" !! '') ~ "\n";
        }

        if $!qualifier eq 'keys' {
            my $action = $!first || 'list';
            if $action eq 'list' {
                my $keys = from-json client.get('/assb_admin/installed_keys', ["exclude_current=true", "include_subscriptions=true"]);
                if $keys<error>:exists {
                    'No keys. Request or install a key to use ASSB.';
                } else {
                    my $current_key = (from-json client.get('/assb_admin/current_key'));
                    $keys{$current_key<key>}:delete;
                    last_uris($keys.keys.map:{ 'assb.keys switch ' ~ $_});
                    my $ren = $current_key<subscription><renews>:exists ??	$current_key<subscription><renews>.substr(0,10) !! '          ';
                    "\n  " ~ ansi($current_key<key>, 'bold') ~ '  ' ~
                    ansi($ren, 'bold red') ~ '  ' ~
                    ansi($current_key<subscription><email>, 'bold green') ~
                    "\n\n  " ~
                    (for $keys.kv -> $key, $subs {
                            my $ren = $subs<renews>:exists ??  $subs<renews>.substr(0,10) !! '          ';
                            $key ~ '  ' ~ ansi($ren, "red") ~ '  ' ~ ansi($subs<email>, 'green');
                        }).join("\n  ") ~ "\n\n";
                }
            } elsif $action eq 'switch' {
                my $key = @!args.first;
                if $key {
                    clear_last_uris();
                    pretty client.post("/assb_admin/switch_key/$key");
                } else {
                    'Please provide a key to swtich to.'
                }
            } elsif $action eq 'request' {
                my ($email, $code) = @!args;
                if $email {
                    if $email ~~ /^ \S+ \@ \S+ $/ {
                        if $code {
                            pretty client.post('/assb_admin/request_key', ["email=$email", "code=$code"]);
                        } else {
                            my $resp = from-json client.post('/assb_admin/request_key', ["email=$email"]);
                            if $resp<error> {
                                pretty to-json $resp;
                            } else {
                                "A confirmation code has been sent to $email. Please repeat this action with that code." ~
                                "\n  For example:\n    assb.keys request $email 123456";
                            }
                        }
                    } else {
                        "That doesn't look much like an email address, so yeah.";
                    }
                } else {
                    "Please provide an email address to send a confirmation code to."
                }

            }
        } elsif $!qualifier eq 'install' {
            pretty client.post('/assb_admin/install/' ~ $!first);
        } elsif $!qualifier eq 'plugins' {
            my $cfg = from-json client.get('/assb_admin/config');
            my $plugins = $cfg<plugins>.sort: { $_<name> };
            my $pending = $cfg<pending_restart> || {};
            my $max = max(@$plugins.map: { $_<name>.chars });
            my $out;
            for @$plugins -> $p {
                $out ~= render-plugin($p, $max, |$pending.grep: { $_<ext> eq $p<name>}.first);
            }
            $out;
        } elsif $!qualifier eq 'catalog' {
            my $cat = (from-json client.get('/assb_admin/catalog'))<plugins>.sort: { $_<name> };
            $cat = $cat.grep: { $_<name>.lc.contains($!first.lc)} if $!first;
            my $max = max(@$cat.map: { $_<name>.chars });

            my $out;
            for @$cat -> $p {
                $out ~= render-plugin($p, $max);
            }
            $out;
        } else {
            pretty client.get('/assb_admin');
        }
    }


    method schedules {
        my %state_color =
            Running => 'bold green',
            Complete => 'bold white',
            Cancelled => 'bold red';

        sub render-schedule($ix) {
            my $s = schedules[$ix];
            return '' unless $s;
            my $ix_fmt = ansi("%02d", 'cyan');
            my $status_fmt = ansi("%-10s", %state_color{$s<command>.state});
            my $runs_fmt = ansi("%d/%s", 'magenta');
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
        sub render-group($groups, $ix) {
            # have to reget it to get the member_usernames
            my $g = from-json(client.get($groups[$ix]<uri>));
            return $g<error> if $g<error>;

            my $ix_fmt = ansi("%02d", 'cyan');
            my $code_fmt = ansi("%-35s", "bold white");
            my $out = sprintf("[$ix_fmt] $code_fmt %s",
                              $ix + 1,
                              $g<group_code>,
                              ansi($g<member_usernames>.sort.join(', '), "bold green"));

            if visible_length($out) > term_cols() {
                my $snip;
                $out.indices(' ').reverse.map({($snip = $_) && last if visible_length($out.substr(0..$_)) < term_cols()});
                $out = $out.substr(0..$snip) ~ "\n" ~ (' ' x 41) ~ $out.substr($snip+1);
            }
            $out;
        }

        sub update-users($g, :$add, :$remove, :$removeall) {
            $g<member_usernames> = [] if $removeall;
            $g<member_usernames> = $g<member_usernames>.push(|$add).Set.keys.sort if $add;
            $g<member_usernames> = $g<member_usernames>.grep(none $remove.grep($_)) if $remove;
            my $resp = from-json client.post($g<uri>, [], to-json($g));
            if $resp<error> {
                pretty to-json $resp;
            } else {
                "Users updated for group {$g<group_code>} in {$g<repository><ref>}";
            }
        }

        if $!first {
            my $repo_id = $!first.Int.so ?? $!first !! repo_map($!first);

            my $repo = from-json(client.get("/repositories/$repo_id"));
            if $repo<error> {
                return pretty to-json $repo
            }

            my $groups = from-json(extract_uris client.get("/repositories/$repo_id/groups"));
            if $groups<error> {
                return pretty to-json $groups
            }

            my $ix = @!args.shift;
            if $ix {
                unless ($ix = $ix.Int) {
                    return 'Give an integer to select a group';
                }
                my $g = from-json(client.get($groups[$ix - 1]<uri>));

                given $!qualifier {
                    when <add> {
                        if @!args {
                            update-users($g, :add(@!args));
                        } else {
                            'Give one or more usernames to add to the group';
                        }
                    }
                    when <remove> {
                        if @!args {
                            update-users($g, :remove(@!args));
                        } else {
                            'Give one or more usernames to remove from the group';
                        }
                    }
                    when <removeall> {
                        update-users($g, :removeall);
                    }
                    default {
                        render-group($groups, $ix - 1);
                    }
                }
            } else {
                (('Groups for repository:',
                  ansi($repo<repo_code>, 'bold yellow'),
                  ansi($repo<name>, 'bold white')).join(' '),
                 |(await (start { render-group($groups, $_) } for ^$groups))).join("\n");
            }
        } else {
            "Give a repo id or code like this:\n> groups 2\n> groups REPO"
        }
    }


    method enums {
        my @enums = enums(:reload($!qualifier eq 'reload'), :name($!first));
        return 'No enumerations matching: ' ~ $!first unless @enums;

        if $!qualifier eq 'add' || $!qualifier eq 'remove' {
            if @enums != 1 {
                return "Must match only one enum to add or remove values. You matched {@enums.elems} with: $!first";
            }

            unless @!args {
                return 'Please provide a value to add or remove';
            }

            my $e = @enums.first;
            my $v = @!args.first;

            if $!qualifier eq 'add' {
                if $e<values>.grep($v) {
                    return "Enumeration '{$e<name>}' already has value '$v'"
                }

                $e<values>.push($v);
            }

            if $!qualifier eq 'remove' {
                unless $e<values>.grep($v) {
                    return "Enumeration '{$e<name>}' doesn't have value '$v' to remove"
                }

                $e<values> = $e<values>.grep({ $_ ne $v}).Array;
            }

            client.post($e<uri>, [], to-json($e));

            enums(:reload(True));

            return "Value '$v' {$!qualifier eq 'add' ?? 'added to' !! 'removed from'} enumeration '{$e<name>}'";
        }

        "\n" ~
        @enums.map(-> $e {
            my $val_len = 4;
            ansi($e<name>, 'bold') ~
            ' [' ~ ($e<editable> ?? ansi('editable', 'green') !! ansi('not editable', 'red')) ~ '] ' ~
            $e<uri> ~ "\n    " ~
            ($e<relationships> ?? ansi($e<relationships>.join(' '), 'cyan') !! '[not used]') ~
            "\n    " ~

            (if $e<value_translations> && $!qualifier eq 'tr' {
                ($e<values>.map(-> $v {
                                       $v ~ ': ' ~ ansi($e<value_translations>{$v}, 'yellow')
                                   })).join("\n    ");
            } else {
                ($e<values>.map(-> $v {
                                       my $prefix = '';
                                       $val_len += $v.chars + 1;
                                       if $val_len >= term_cols() {
                                           $val_len = 4 + $v.chars + 1;
                                           $prefix = "\n    ";
                                       }
                                       $prefix ~ ($e<readonly_values>.grep($v) ?? ansi($v, 'red') !! $v);
                                   })).join(' ');
            });

        }).join("\n\n") ~ "\n\n";
    }


    method help {
        if $!first {
            if $!qualifier eq 'write' {
                if edit(store.path(Pas::Help.new(:store(store)).file($!first))) {
                    "Help saved.";
                } else {
                    'No changes to save.';
                }
            } else {
                Pas::Help.new(:store(store)).topic($!first);
            }
        } elsif $!qualifier eq 'list' {
            Pas::Help.new(:store(store)).list;
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
       .public  show pui document
      revisions show revision history
       .restore attempt to restore revision n
       n        show revision n
       n/[m]    show diff between n and m (default n - 1)
       n//[m]   show inline diff between n and m (default n - 1)
       +cnt     show cnt revisions in list (default 20)
       ;user    only show revisions by user
       -date    only show revisions at or before date
       ,rev     only show revisions up to rev
      doc       show endpoint documentation for uri
       .get     GET method only
       .post    POST method only
       .delete  DELETE method only

    other actions:
      login     force a login
       .prompt  prompt for details
      users     list users
       .create  create a user
         name   with username and password set to name
       .me      show the current user
       .pass    set password for current user
         name   set password for user name
      group     no op without repo_id
       .add     add user to group
       .remove  remove user from group
       .removeall remove all users from group
       repo_id  list groups for repo_id
       [n]      group listing number
       user     the user to add or remove
      enums     list enumerations
       .add     add val to enum str
       .remove  remove val from enum str
       .reload  force a reload
       .tr      include translations for values
       [str]    show enumerations that match str
       [val]    value to add or remove
      import    import data
       repo     repo code to import into
       type     import type
       files+   list of file paths
      revisions show revision history
       +cnt     show cnt revisions in list (default 20)
       =model   only show revisions for model
       ;user    only show revisions by user
       -date    only show revisions at or before date
       -[n]d    only show revisions at n days ago
      session   show sessions or switch to a session
       .delete  delete a session
      schedules show current schedules
        .cancel cancel numbered schedule
        .clean  remove all completed schedules
        [n]     show or cancel numbered schedule
      script    run a pas script file
      endpoints show the available endpoints
       .reload  force a reload
       [str]    show endpoints that include str
      schemas   show all record schemas
       .reload  force a reload
       .property show schemas with a property that matches name
       [name]   show a named record schema, or list that match name
      search    perform a search (page defaults to 1)
       .parse   parse the 'json' property
       q        the query string
       [n]      page number (defaults to 1)
      find      formatted search
       q        the query string
       [=m]+    only show results for model m
       [,n]     page number (defaults to 1)
      config    show pas config
      last      show the last saved temp file
      set       show pas properties
       .[prop]  show or set prop
      history   show command history
       [n]      show the last n commands 
      assb      sail boats
      help      this
       .list    list help topics
       .write   write help for topic
       topic    the topic to write or read
      quit      exit pas (^d works too)

      < file    post file to uri
      > file    redirect output to file instead of displaying
                if file is 'null' then don't display or save

      @d[xt]    schedule command to run t times (default 1) every d seconds
                d of * means 0.01, t of * means forever
                obviously take care with these and ensure set.spool is on

    Say 'help [action]' for detailed help. ... well, not yet

    Use the <tab> key to cycle through completions for uris or actions.
    Some actions have context sensitive completions.

    Command history and standard keybindings.
END
}
