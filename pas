#!/usr/bin/env perl6

use lib 'lib';
use Config;
use Command;
use Functions;

use Linenoise;


sub MAIN(Str  :$e?, Bool :$h) {

    if $h { help; exit; }

    config.load;
    apply_property_defaults;
    
    if $e { run_cmd $e; exit; }

    load_endpoints;

    linenoiseHistoryLoad(pas_path HIST_FILE);
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
    }

    linenoiseHistorySave(pas_path HIST_FILE);

}
