use Config;
use Pas::ASClient;
use Functions;

use Linenoise;
use Terminal::ANSIColor;
use JSON::Tiny;


class Command {
    has     $.client;
    has Str $.line;
    has Str $.action;
    has Str $.qualifier = '';
    has     $!first;
    has     @.args;
    
    my constant ACTIONS = <show update create edit stub post search nav
                           login logout run
                           endpoints schemas config session user who
                           history last set ls help quit>;

    method actions { ACTIONS }


#    method client { $!client ||= client; }


    method execute {
    	($!action, $!qualifier) = $!action.split('.', 2);
    	@!args ||= [''];
	$!first = @!args.shift;
	for @!args -> $arg is rw {
	    $arg ~~ s/^ 'p='/page=/;
	    $arg ~~ s/^ 'r='/resolve[]=/;
	    $arg ~~ s/^ 't='/type[]=/;
	    $arg ~~ s/^ 'u='/uri[]=/;
	}
	$!qualifier ||= '';
	(ACTIONS.grep: $!action) ?? self."$!action"() !! "Unknown action: $!action";
    }


    method show {
        pretty extract_uris client.get($!first, @!args);
    }


    method update {
	pretty extract_uris client.post($!first, @!args, modify_json(client.get($!first), @!args));
    }


    method create {
	pretty extract_uris client.post($!first, @!args, modify_json('{}', @!args));
    }


    method edit {
        save_tmp(pretty extract_uris client.get($!first)) unless $!qualifier eq 'last';
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

        save_tmp(pretty client.get('/stub/' ~ $model, @!args));

	my Int $times = (so $!qualifier.Int) ?? $!qualifier.Int !! 1;
	if edit(tmp_file) {
	    my $out = '';
	    my $json = slurp(tmp_file);
	    for ^$times -> $c { $out ~= $c+1 ~ ' ' ~ pretty extract_uris client.post($!first, @!args, interpolate($json, $c+1)) }
	    $out;
	} else {
	    'No changes to post.';
	}
    }


    method post {
	my $post_file = @!args.pop;
	pretty extract_uris client.post($!first, @!args, slurp($post_file));
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
	    @!args.push("q=$!first");
	    @!args.push('page=1') unless @!args.grep(/^ 'page='/);
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

    my Int $x;
    my Int $y;
    my Int $y_offset;
    my Str @uris;
    my Hash %uri_cache;
    my $current_uri;
    my $term_cols;
    my $term_lines;
    my Str $default_nav_message;
    my Str $nav_message;
    
    sub nav_message(Str $message = '', Bool :$default, Bool :$set_default) {
	$default_nav_message ||= '';
	$x ||= 0;
	$y ||= 0;
	$nav_message = $message if $message;
	$default_nav_message = $message if $set_default;
	$nav_message = $default_nav_message if $default;
	run 'tput', 'civis'; # hide the cursor
	print_at($nav_message, 0, 0);;
	cursor($x, $y);
	run 'tput', 'cvvis'; # show the cursor
    }

    sub clear_screen {
	print state $ = qx[clear];
	nav_message;
    }
    
    sub plot_uri(Str $uri, @args = (), Bool :$reload) {
	%uri_cache ||= Hash.new;

	my $raw_json;
	if %uri_cache{$uri} && !$reload {
	    $raw_json = %uri_cache{$uri}<json>;
	} else {
	    nav_message("getting $uri ...");
	    $raw_json = client.get($uri, @args);
	    nav_message(:default);
	    %uri_cache{$uri} = { json => $raw_json, y => 10 };
	}

	%uri_cache{$current_uri}<y> = $y if $current_uri && %uri_cache{$current_uri};
	$current_uri = $uri;
	
	my %json = from-json extract_uris $raw_json;

	return False if %json<error>:exists;
	
	$term_cols = q:x/tput cols/.chomp.Int; # find the number of columns
	$term_lines = q:x/tput lines/.chomp.Int; # find the number of lines
	run 'tput', 'civis';                   # hide the cursor
	clear_screen;

	print_at(record_label(%json), 2, 8);
	print_at($uri, 4, 10);
	@uris = ($uri);
	$y = 11;
	$y_offset = 10;
	
	plot_hash(%json, 'top', 6);

	$x = 2;
	$y = %uri_cache{$uri}<y>;
	cursor($x, $y);
	run 'tput', 'cvvis'; # show the cursor
    }

    sub plot_hash(%hash, $parent, $indent) {
	return if $y >= $term_lines;
	for %hash.kv -> $prop, $val {
	    if $prop eq 'ref' || $prop eq 'record_uri' {
		plot_ref($val, %hash, $parent, $indent);
	    }
	    if $val.WHAT ~~ Hash {
		plot_hash($val, $prop, $indent);
	    } elsif $val.WHAT ~~ Array {
		for $val.values -> $h {
		    last if $y >= $term_lines;
		    if $h.WHAT ~~ Hash {
			plot_hash($h, $prop, $indent);
		    }
		}
	    }
	}
    }

    sub plot_ref($uri, %hash, $parent, $indent) {
	my $s = sprintf "%-41s %s", $uri, link_label($parent, %hash);
	print_at($s, $indent, $y);
	@uris.push($uri);
	$y++;
    }

    my constant RECORD_LABEL_PROPS = <long_display_string display_string title name>;
    
    sub record_label(%hash) {
	my $label = (RECORD_LABEL_PROPS.map: {%hash{$_}}).grep(Str)[0];
	$label ~~ s:g/'<' .+? '>'// if $label;;
	$label;
    }

    my constant LINK_LABEL_PROPS = <role relator level identifier display_string description>;

    sub link_label($prop, %hash) {
	my $label = $prop;
	LINK_LABEL_PROPS.map: { $label ~= ": %hash{$_}" if %hash{$_} }
	my $record;
	if %hash<_resolved>:exists {
	    $record = record_label(%hash<_resolved>);
	} else {
	    $record = record_label(%hash);
	}
	$label ~= " > $record" if $record;
	$label ~~ s:g/'<' .+? '>'//;
	$label;
    }

    sub print_at($s, $col, $row) {
	cursor($col, $row);
	$term_cols ||= q:x/tput cols/.chomp.Int; # find the number of columns
	$term_lines ||= q:x/tput lines/.chomp.Int; # find the number of lines
	printf("%.*s", ($term_cols - $col), $s) if $row <= $term_lines;
    }
    
    my constant UP_ARROW    =  "\x[1b][A";
    my constant DOWN_ARROW  =  "\x[1b][B";
    my constant RIGHT_ARROW =  "\x[1b][C";
    my constant LEFT_ARROW  =  "\x[1b][D";
    my constant BEL         =  "\x[07]";
    
    method nav {
	my $uri = $!first;
	nav_message(cmd_prompt() ~ " $!line", :set_default);
	my Bool $new_uri = True;
	my $c = '';
	my @uri_history = ();
	my $message = '';
	while $c ne 'q' {
	    if $new_uri {
		plot_uri($uri, @!args) || ($message = "No record for $uri") && last;
		print_at('.' x @uri_history, 2, 4);
		cursor($x, $y);
		$new_uri = False;
	    }
	    
	    $c = get_char;
	    if $c eq "\x[1b]" {
		$c = $c ~ get_char() ~ get_char();
		# say $c.ords;
		given $c {
		    when UP_ARROW {
			if $y > $y_offset {
			    $y--;
			} else {
			    print BEL;
			}
		    }
		    when DOWN_ARROW {
			if $y < $y_offset + @uris.elems - 1 {
			    $y++;
			} else {
			    print BEL;
			}
		    }
		    when RIGHT_ARROW {
			@uri_history.push: $uri;
			$uri = @uris[$y-$y_offset];
			$new_uri = True;
		    }
		    when LEFT_ARROW {
			if @uri_history {
			    $uri = @uri_history.pop;
			    $new_uri = True;
			} else {
			    print BEL;
			}
		    }
		}
	    } else {
		given $c {
		    when ' ' {
			page(pretty client.get(@uris[$y-$y_offset]));
		    }
		}
	    }
	    cursor($x, $y);
	}
	nav_message(' ');
	clear_screen;
	cursor(0, q:x/tput lines/.chomp.Int);
	%uri_cache = Hash.new;
	$current_uri = Str.new;

	$message;
    }

    sub get_char {
	ENTER shell "stty raw -echo min 1 time 1";
	LEAVE shell "stty sane";
	$*IN.read(1).decode;
    }

    
    method login {
	config.prompt if $!qualifier eq 'prompt' || config.attr<user> eq ANON_USER;
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
	    (for config.attr<sessions>.kv -> $k, $v {
		    sprintf("%-25s  %-25s  %s",
			    $v<time> ?? DateTime.new($v<time>).local.truncated-to('second') !! '[unauthenticated]',
			    colored($k, config.attr<user> eq $k ?? 'bold green' !! 'bold white'),
			    $v<url>);
		}).join("\n");
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
			       $out = colored('on', 'green') if $out.WHAT ~~ Bool && $out;
			       $out = colored('off', 'red') if $out.WHAT ~~ Bool && !$out;
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
		    $!qualifier ~ colored(' off', 'red');
		} elsif $!first ~~ /./ {
		    %prop{$!qualifier} = True;
		    config.save;
		    $!qualifier ~ colored(' on', 'green');
		} else {
		    $!qualifier ~ (%prop{$!qualifier} ?? colored(' on', 'green') !! colored(' off', 'red'));
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


    method ls {
	qq:x/$!line/.trim;
    }


    method help {
	shell_help;
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

    my %cmd = parse_cmd($line);

    my $intime = now;
    display Command.new(line => $line, action => %cmd<action>, args => %cmd<args>.list).execute;
    say colored(((now - $intime)*1000).Int ~ ' ms', 'cyan') if config.attr<properties><time>;
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
		    search    show search index document

    other actions:  login     force a login
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
                    config    show pas config
                    last      show the last saved temp file
                    set       show pas properties
                     .[prop]  show or set prop
		    history   show command history
		     [n]      show the last n commands 
                    help      this
                    quit      exit pas (^d works too)

    say 'help [action]' for detailed help. ... well, not yet

    Use the <tab> key to cycle through completions for uris or actions.

    Command history and standard keybindings.

END
}
