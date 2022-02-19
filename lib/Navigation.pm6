use Functions;
use Terminal::ANSIColor;
use JSON::Tiny;

unit class Navigation;
has $.uri;
has @.args;
has $.line;

my Int $x = 0;
my Int $y = 0;
my Int $nav_cursor_col = 50;
my Int $y_offset = 6;
my Hash @uris;
my Hash %uri_cache;
my $current_uri;
my @resolves;
my %current_refs;
my $term_cols;
my $term_lines;
my Str $default_nav_message;
my Str $nav_message;
my Int $nav_page_size;
my Int $current_nav_offset = 0;

my constant UP_ARROW    =  "\x[1b][A";
my constant DOWN_ARROW  =  "\x[1b][B";
my constant RIGHT_ARROW =  "\x[1b][C";
my constant LEFT_ARROW  =  "\x[1b][D";
my constant BEL         =  "\x[07]";

my constant RECORD_LABEL_PROPS = <long_display_string display_string title name
                                  last_page outcome_note jsonmodel_type>;

my constant RECORD_SUMMARY_ARRAYS = <dates extents instances notes rights_statements
           	     		     external_ids external_documents revision_statements
			             terms names agent_contacts>;

my constant LINK_LABEL_PROPS = <role relator level identifier display_string description>;


method start {
    my $uri = $!uri;
    nav_message(cmd_prompt() ~ " $!line", :set_default);
    clear_screen;
    my Bool $new_uri = True;
    my $c = '';
    my @uri_history = ();
    my $message = '';
    @resolves = @!args || ();
    while $c ne 'q' {
	if $new_uri {
	    plot_uri($uri, @resolves) || ($message = "No record for $uri") && last;
	    print_at('.' x @uri_history, 2, 1);
	    print_at(ansi('h', 'bold') ~ 'elp ' ~ ansi('q', 'bold') ~ 'uit',
		     $term_cols - 9, 1);
	    cursor($x, $y);
	    $new_uri = False;
	}
	
	$c = get_char;
	if $c eq "\x[1b]" {
	    $c = $c ~ get_char() ~ get_char();
	    given $c {
		when UP_ARROW {
		    if $y > $y_offset {
			clear_nav_cursor;
			$y--;
			print_nav_cursor;
		    } else {
			if $current_nav_offset > 0 {
			    print_nav_page($current_nav_offset - $nav_page_size, $y_offset);
			} else {
			    print BEL;
			}
		    }
		}
		when DOWN_ARROW {
		    if $y < $y_offset + @uris - $current_nav_offset - 1 && $y < $term_lines - 2 {
			$y++;
			print_nav_cursor($y-1);
		    } else {
			if @uris > $current_nav_offset + $nav_page_size {
			    print_nav_page($current_nav_offset + $nav_page_size, $y);
			} else {
			    print BEL;
			}
		    }
		}
		when RIGHT_ARROW {
		    if $y == $y_offset {
			print BEL;
		    } else {
			@uri_history.push: $uri;
			$uri = @uris[$y-$y_offset+$current_nav_offset]<uri>;
			$new_uri = True;
		    }
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
	    my $yix = $y - $y_offset;
	    my %selected = @uris[$yix];
	    given $c {
		when ' ' {
        page(pretty client.get(%selected<uri>,
                               to_resolve_params(@resolves)));
		}
		when "\r" {
        page(stripped pretty client.get(%selected<uri>,
                                        to_resolve_params(@resolves)));
		}
		when 'e' {
		    plot_edit(%selected<uri>, @resolves) || ($message = "No record for $uri");
		    get_char;
		    plot_uri($uri, @resolves) || ($message = "No record for $uri");
		}
		when 'r' {
		    if @resolves.grep(%current_refs{$y-$y_offset}) {
			@resolves = @resolves.grep: { $_ ne %current_refs{$y-$y_offset} };
		    } else {
			@resolves.push(%current_refs{$y-$y_offset});
		    }
		    %uri_cache{$current_uri}:delete;
		    $new_uri = True;
		}
		when 'h' {
		    nav_help;
		    $new_uri = True;
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
    last_uris(map { $_<uri> }, @uris);
    $message;
}


sub cursor(Int $col, Int $row) {
    print "\e[{$row};{$col}H";
}


sub get_char {
    ENTER shell "stty raw -echo min 1 time 1";
    LEAVE shell "stty sane";
    $*IN.read(1).decode;
}


sub print_at($s, $col, $row, Bool :$fill) {
    cursor($col, $row);
    $term_cols ||= q:x/tput cols/.chomp.Int; # find the number of columns
    $term_lines ||= q:x/tput lines/.chomp.Int; # find the number of lines
    printf("%-*.*s", ($fill ?? $term_cols - $col !! $s.chars, $term_cols - $col + (+$s.perl.comb: /'\x'/)*4), $s) if $row <= $term_lines;
}


sub nav_message(Str $message = '', Bool :$default, Bool :$set_default) {
    $default_nav_message ||= '';
    $x ||= 0;
    $y ||= 0;
    $nav_message = $message if $message;
    $default_nav_message = $message if $set_default;
    $nav_message = $default_nav_message if $default;
    run 'tput', 'civis'; # hide the cursor
    $term_lines ||= q:x/tput lines/.chomp.Int;
    print_at(sprintf("%-*s", $term_cols - 1, $nav_message), 0, $term_lines);
    cursor($x, $y);
    run 'tput', 'cvvis'; # show the cursor
}


sub clear_screen {
    print state $ = qx[clear];
    nav_message;
}


sub clear_nav_cursor($line = False) {
    print_at(' ', $nav_cursor_col, $line || $y);
}


sub print_nav_cursor(Int $clear = 0) {
    clear_nav_cursor($clear) if $clear;
    print_at(ansi('>', 'bold'), $nav_cursor_col, $y) unless $y == $y_offset && $current_nav_offset == 0;
}


sub to_resolve_params(@args) {
    @args.map: { / '=' / ?? $_ !! 'resolve[]=' ~ $_};
}

sub edit_uri($uri) {

}

sub plot_edit(Str $uri, @args = (), Bool :$reload) {
    my %rec = from-json client.get($uri);
    my $c = '';
    my $refresh = True;
    while $c ne 'q' {
	print_at(%rec.map({ .perl.say }), 4, 2) if $refresh;
	$refresh = False;
	$c = get_char;
	given $c {
	    when "\r" {
		client.post($uri, @args, to-json %rec);
		$refresh = True;
	    }
	}
    }
}

sub plot_uri(Str $uri, @args = (), Bool :$reload) {
    %uri_cache ||= Hash.new;

    my %json;
    if %uri_cache{$uri} && !$reload {
	%json = %uri_cache{$uri}<json>;
    } else {
	nav_message("getting $uri ...");
	my $raw_json = client.get($uri, to_resolve_params(@args));
	nav_message("parsing $uri ...");
	%json = from-json $raw_json;
	return False if %json<error>:exists;
	%uri_cache{$uri} = { json => %json.clone, y => $y_offset, offset => 0 };
	nav_message(:default);
    }

    if (%uri_cache{$current_uri}:exists) {
	%uri_cache{$current_uri}<y> = $y;
	%uri_cache{$current_uri}<offset> = $current_nav_offset;
    }
    $current_uri = $uri;

    nav_message("plotting $uri ...");
    $term_cols = q:x/tput cols/.chomp.Int; # find the number of columns
    $term_lines = q:x/tput lines/.chomp.Int; # find the number of lines
    run 'tput', 'civis';                   # hide the cursor
    clear_screen;

    print_at(ansi(record_label(%json).Str, 'bold'), 2, 3);
    print_at(record_summary(%json), 6, 4);
    print_at(ansi($uri, 'bold'), 4, 6);
    @uris = Array.new;
    @uris.push(uri_hash($uri, 'top', ansi($uri, 'bold'), 4));
    $y = 7;

    plot_hash(%json, 'top', 6);
    $nav_page_size = $term_lines - $y_offset - 2;
    print_nav_page(%uri_cache{$current_uri}<offset>, %uri_cache{$current_uri}<y>);
	
    $x = 2;
    $y = %uri_cache{$uri}<y>;
    cursor($x, $y);
    run 'tput', 'cvvis'; # show the cursor
    nav_message(:default);
}


sub uri_hash($uri, $ref, $label, $indent) {
    (uri => $uri, ref => $ref, label => $label, indent => $indent).Hash;
}

sub plot_hash(%hash, $parent, $indent) {
    my $found_ref = 0;
    for %hash.keys.sort: { %hash{$^a}.WHAT ~~ Str ?? -1 !! 1 } -> $prop {
	my $val = %hash{$prop};
	if $prop eq 'ref' || $prop eq 'record_uri' || ($parent eq 'results' && $prop eq 'uri') {
	    plot_ref($val, %hash, $parent, $indent);
	    $found_ref = 1;
	} elsif $val.WHAT ~~ Hash {
	    plot_hash($val, $prop, $indent+$found_ref);
	} elsif $val.WHAT ~~ Array {
	    for $val.values -> $h {
		last if $y >= $term_lines;
		if $h.WHAT ~~ Hash {
		    plot_hash($h, $prop, $indent+$found_ref);
		}
	    }
	}
    }
}


sub plot_ref($uri, %hash, $parent, $indent) {
    my $s = sprintf "%-*s %s", $nav_cursor_col - 5, $uri, link_label($parent, %hash);
    @uris.push(uri_hash($uri, $parent, $s, $indent));
}


sub print_nav_page(Int $offset, Int $cursor_y) {
    %current_refs = Hash.new;
    $current_nav_offset = ($offset, 0).max;
    my $last_y = $y;
    my $has_next_page = so @uris > $offset + $nav_page_size;
    for ($offset..$offset + $nav_page_size) {
	if @uris[$_]:exists {
	    my %ref = @uris[$_];
	    %current_refs{$_} = %ref<ref>;
	    print_at(' ' x %ref<indent> ~ %ref<label>, 0, $_ - $offset + $y_offset, :fill);
	    $last_y = $_ - $offset + $y_offset;
	} else {
	    print_at(' ', 0, $_ - $offset + $y_offset, :fill);
	}
    }
    $y = ($last_y, $cursor_y).min;
    print_nav_cursor;
    print_at('^', 1, $y_offset) if $offset > 0;
    print_at('v', 1, $nav_page_size + $y_offset) if $has_next_page;
}
    

sub record_label(%hash) {
    my $label = (RECORD_LABEL_PROPS.map: {%hash{$_}}).grep(Cool)[0];
    $label ~~ s:g/'<' .+? '>'// if $label;
    $label;
}


sub record_summary(%hash) {
    RECORD_SUMMARY_ARRAYS.map: {
	$_ ~ ': ' ~ %hash{$_}.elems if %hash{$_}:exists && %hash{$_} > 0;
    }
}


sub link_label($prop, %hash) {
    my $label = $prop;
    LINK_LABEL_PROPS.map: { $label ~= ": %hash{$_}" if %hash{$_} }
    my $record;
    if %hash<_resolved>:exists {
	$record = record_label(%hash<_resolved>);
    } else {
	$record = record_label(%hash);
    }
    $label ~= "  > $record" if $record;
    $label ~~ s:g/'<' .+? '>'//;
    $label;
}


sub print_nav_help($s, $line) {
    print_at(" $s", $term_cols - 50, $line, :fill);
}


sub nav_help {
    run 'tput', 'civis'; # hide the cursor
    print_nav_help('', 1);
    print_nav_help(ansi('UP', 'bold') ~ '/' ~ ansi('DOWN', 'bold') ~ '  Select Previous/Next uri', 2);
    print_nav_help(ansi('LEFT', 'bold') ~ '     Back to last uri', 3);
    print_nav_help(ansi('RIGHT', 'bold') ~ '    Load selected uri', 4);
    print_nav_help(ansi('SPACE', 'bold') ~ '    View json for selected uri', 5);
    print_nav_help(ansi('RETURN', 'bold') ~ '   View summary for selected uri', 6);
    print_nav_help(ansi('r', 'bold') ~ '        Resolve refs like the selected uri', 7);
    print_nav_help(ansi('q', 'bold') ~ '        Quit navigator', 8);
    print_nav_help(ansi('h', 'bold') ~ '        This help', 9);
    print_nav_help('', 10);
    print_nav_help(ansi('    <ANY KEY> to exit help', 'bold'), 11);
    print_nav_help('', 12);
    get_char;
    cursor($x, $y);
    run 'tput', 'cvvis'; # show the cursor
}
    

sub stripped($t) {
    # this should be a grammar
    my @dropped = <lock_version created_by last_modified_by create_time
                   system_mtime user_mtime jsonmodel_type>;

    my @tl = grep -> $line {
	      (!grep -> $field { $line.index($field) }, @dropped) && $line !~~ / '[]' /;
    }, $t.lines;

    @tl = map {
	      my $line = $_;
	      if $line.chars > $term_cols-2 {
	          my $left = ($line.index('":') + 1) || $line.index('"') || 10;
	          my $offset = $term_cols;
	          while $offset < $line.chars {
		            my $off = $line.substr(0, $offset).rindex(' ') || $offset;
		            $off += 1 unless $off == $offset;
		            # $line = $line.substr(0, $off) ~ "\n" ~ ' ' x $left ~ $line.substr($off);
		            $line.substr-rw($off, 0) = "\n" ~ ' ' x $left;
                last if $line.chars - ($offset + ("\n" ~ ' ' x $left).chars) < $term_cols-2;
		            $offset = $off + ($term_cols-2);
	          }
	      }
	      $line;
    }, @tl;

    my $out = @tl.join("\n");

    $out ~~ s:g/ (<-[\\]>) '"'/$0/;
    $out ~~ s:g/ '\"'/\x22/; # avoiding explicit " so emacs mode doesn't freak out
    $out ~~ s:g/",\n"/\n/;
    $out ~~ s:g/^^ \s* '[' $$/\n/;
    $out ~~ s:g/^^ \s* ']' $$//;
    $out ~~ s:g/\s* '}' \s* '{'/\n/;
    $out ~~ s:g/^^ \s* '{' \n//;
    $out ~~ s:g/^^ \s* '}' \n?//;

    $out;
}
