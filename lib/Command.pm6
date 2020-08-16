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
    has Str $.first is rw;
    has Str @.args is rw;


    my constant ACTIONS = <show update create edit stub post delete
                           search nav login logout run
                           endpoints schemas config session user who
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
        token TOP           { <.ws> [ <uricmd> | <actioncmd> | <comment> ] <.ws> }

        rule  uricmd        { <uri> <pairlist> <action>? <postfile>? <redirect>? }
        rule  actioncmd     { <action> <arglist> <redirect>? }
        token comment       { '#' .* }

        token uri           { '/' <[\/\w]>* }
        rule  pairlist      { <pairitem>* }
        rule  pairitem      { <pair> }
        token pair          { <key=.refpath> '=' <value> }
        token refpath       { <[\w\.\d\[\]]>+ }
        token action        { <arg> <qualifier>? }
        token qualifier     { '.' <arg> }
        rule  arglist       { <argitem>* }
        rule  argitem       { <arg> }
        token arg           { <[\w\d]>+ }
        token value         { [ <str> | <singlequoted> | <doublequoted> ] }
        token str           { <-['"\\\s]>+ }
        token singlequoted  { "'" ~ "'" (<-[']>*) }
        token doublequoted  { '"' ~ '"' (<-["]>*) }

        rule  postfile      { '<' <file> }
        rule  redirect      { '>' <file> }
        token file          { <[\w/\.\-]>+ }
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
        method argitem($/)    { $!cmd.args.push($<arg>.Str) }

        method postfile($/)   { $!cmd.action = 'post'; $!cmd.postfile = $<file>.Str }
        method redirect($/)   { $!cmd.savefile = $<file>.Str; save_file($!cmd.savefile) }
    }


    submethod BUILD(:$line) {
        if $line.trim {
            Grammar.parse($line, :actions(ParseActions.new(cmd => self)));
            logger.blurt(self.gist);
            if self.action {
                display (ACTIONS.grep: self.action) ?? self."{self.action}"() !! "Unknown action: " ~ self.action;
            } else {
                say 'What?';
            }
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
    

    method run {
        if $!first.IO.e {
            for slurp($!first).lines -> $line {
                next unless $line;
                say cmd_prompt() ~ $line;
                Command.do($line);
            }
        } else {
            'Script file not found: ' ~ $!first;
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
    qq:heredoc/END/;

    pas shell help

    uri pairs* action? [ < file ] [ > file ]
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
      run       run a pas script file
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

    Say 'help [action]' for detailed help. ... well, not yet

    Use the <tab> key to cycle through completions for uris or actions.

    Command history and standard keybindings.
END
}
