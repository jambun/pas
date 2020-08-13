use Config;
use Pas::CommandParser;
use Pas::ASClient;
use Pas::Help;
use Functions;
use Navigation;

use Linenoise;
use Terminal::ANSIColor;
use JSON::Tiny;


class Command {
    has     $.client;
    has Str $.line;
    has     $.uri;
    has Str $.action;
    has     $.qualifier;
    has     $!first;
    has     @.args;
    
    my constant ACTIONS = <show update create edit stub post delete
                           search nav login logout run
                           endpoints schemas config session user who
                           history last set ls help quit>;

    method actions { ACTIONS }


    #    method client { $!client ||= client; }


    method execute {
        $!first = $!uri || (@!args || ['']).shift;
        $!qualifier ||= '';
        (ACTIONS.grep: $!action) ?? self."$!action"() !! "Unknown action: $!action";
    }


    method show {
        pretty extract_uris client.get($!first, @!args);
    }


    method update {
        if ($!qualifier eq 'no_get') {
            pretty extract_uris client.post($!first, @!args, 'nothing');
        } else {
            my $json = client.get($!first);
            if (from-json($json)<error>) {
                pretty $json;
            } else {
              pretty extract_uris client.post($!first, @!args, modify_json($json, @!args));
            }
        }
    }


    method create {
        pretty extract_uris client.post($!first, @!args, modify_json('{}', @!args));
    }


    method edit {
        if ($!qualifier eq 'no_get') {
            save_tmp('');
        } else {
            save_tmp(pretty extract_uris client.get($!first)) unless $!qualifier eq 'last';
        }
        edit(tmp_file) ?? pretty extract_uris client.post($!first, @!args, slurp(tmp_file)) !! 'No changes to post.';
    }


    method stub {
        my $puri = $!first;
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
                pretty extract_uris client.post($!first,
                                                @!args,
                                                interpolate(remove_comments($json), $c+1))
            }
            $out;
        } else {
            'No changes to post.';
        }
    }


    method post {
        my $post_file = @!args.pop;
        pretty extract_uris client.post($!first, @!args, slurp($post_file));
    }


    method delete {
        pretty extract_uris client.delete($!first);
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
            my $page = @!args.head || '1';
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
        Navigation.new(uri =>$!first, args =>@!args, line => $!line).start;
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
                run_cmd $line;
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


sub parse_cmd(Str $cmd) {
    my %out;
    my $c = $cmd.trim;
    $c ~~ s/\s* \> \s* (\S+) $/{save_file($0.Str); ''}/;
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


sub run_cmd(Str $line) is export {
    return unless $line.trim;

    return if $line ~~ /^ '#' /;

    my $cmd = Pas::CommandParser::parse($line);

    logger.blurt($cmd.gist);

    unless ($cmd) {
        say 'What?';
        return;
    }

    save_file($cmd<redirect>);

    my $intime = now;
    display Command.new(line => $line, action => $cmd<action>, args => $cmd<args>.flat.Array, uri => $cmd<uri>, qualifier => $cmd<qualifier>).execute;
    say colored(((now - $intime)*1000).Int ~ ' ms', 'cyan') if config.attr<properties><time>;
}


sub shell_help {
    qq:heredoc/END/;

    pas shell help

    uri pairs* action? [ > file ]
    uri pairs* file
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
