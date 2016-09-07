use Config;
use Pas::ASClient;
use Functions;

use Linenoise;
use Terminal::ANSIColor;


class Command {
    has     $.client;
    has Str $.line;
    has Str $.action;
    has Str $.qualifier = '';
    has     $!first;
    has     @.args;
    
    my constant ACTIONS = <show update create edit stub post login logout run
                           endpoints schemas config session user who
                           last set ls help quit>;

    method actions { ACTIONS }


#    method client { $!client ||= client; }


    method execute {
    	($!action, $!qualifier) = $!action.split('.', 2);
    	@!args ||= [''];
	$!first = @!args.shift;
	for @!args -> $arg is rw {
	    $arg ~~ s/^ 'p='/page=/;
	    $arg ~~ s/^ 'r='/resolve[]=/;
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
    

    method endpoints {
    	load_endpoints.join("\n");
    }


    method schemas {
	schemas(:reload($!qualifier eq 'reload'));
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
		apply_property_defaults(:force);
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


sub run_cmd(Str $line) is export {
    return unless $line.trim;

    return if $line ~~ /^ '#' /;

    my %cmd = parse_cmd($line);

    my $intime = now;
    display Command.new(line => $line, action => %cmd<action>, args => %cmd<args>.list).execute;
    say colored(((now - $intime)*1000).Int ~ ' ms', 'cyan') if config.attr<properties><time>;
}
