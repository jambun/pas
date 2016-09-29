#!/usr/bin/env perl6

use lib 'lib';
use Config;
use Command;
use Functions;

use Linenoise;

my constant HIST_FILE     = 'history';
my constant HIST_LENGTH   = 100;


sub MAIN(Str :$e?, Bool :$h) {

    if $h { help; exit; }

    config.load;
    config.apply_property_defaults;

    client.ensure_session;
    
    if $e { run_cmd $e; exit; }

    load_endpoints;

    linenoiseHistoryLoad(store.path(HIST_FILE));
    linenoiseHistorySetMaxLen(HIST_LENGTH);

    linenoiseSetCompletionCallback(-> $line, $c {
        my $prefix  = '';
	my $last = $line;
	if $line ~~ /(.* \s+) (<[\S]>+ $)/ {
	    $prefix = $0;
	    $last = $1;
	}

	# FIXME: this is pretty worky, but totally gruesome
	# making tab targets work when param bits of uris (eg :id) have values
	my @m = $last.split('/');
	my $mf = @m.pop;
#	for tab_targets.map({
	for (|last_uris, |Command.actions, |tab_targets).map({
            my @t = .split('/');
	    if @m.elems >= @t.elems {
		'';
	    } else {
		my @out;
		for zip @m, @t -> ($m, $t) {
	       	    @out.push($m) if $t ~~ /^ ':' / || $t eq $m;
		}
		if @out.elems == @m.elems && @t[@m.elems] ~~ /^ "$mf" / {
	       	    (|@m, |@t[@m.elems .. @t.end]).join('/');
		} else {
	       	    '';
		}
	    }
        }).grep(/./) -> $m {
       	    linenoiseAddCompletion($c, $prefix ~ $m);
	}
				      });

    while (my $line = linenoise cmd_prompt).defined {
	linenoiseHistoryAdd($line.trim) if $line.trim;
	
	run_cmd $line;

	linenoiseHistorySave(store.path(HIST_FILE));
    }

}


sub help {
    say q:heredoc/END/;

pas - a terminal client for ArchivesSpace

    pas             Start pas interactive shell
    pas -e cmd      Evaluate cmd and write output to stdout
    pas -h          This.

END
}
