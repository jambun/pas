use Functions;
use NavCache;
use Terminal::ANSIColor;
use JSON::Tiny;

unit class Navigation;
has $.uri;
has @.args;
has $.line;

my Int $x = 0;
my Int $y = 0;
my Int $nav_cursor_col = 1;

# rows from top of page where nav links start
# gets set in plot_nav_page - changes depending on tree
my Int $y_offset = 7;

#my Hash @uris;
my $current_uri;
my @resolves;
my %current_refs;
my $term_cols;
my $term_lines;
my Str $default_nav_message;
my Str $nav_message;
my Int $current_nav_offset = 0;
my Bool $show_tree = False;
my Int $cursor_line = 1;
my %cursor_marks;
my $nav_cache;
my $tree_indent = 6;

my constant UP_ARROW    =  "\x[1b][A";
my constant DOWN_ARROW  =  "\x[1b][B";
my constant RIGHT_ARROW =  "\x[1b][C";
my constant LEFT_ARROW  =  "\x[1b][D";
my constant BEL         =  "\x[07]";

my constant RECORD_ID_PROPS = <id_0 component_id digital_object_id>;

my constant RECORD_LABEL_PROPS = <long_display_string display_string title name
                                  last_page outcome_note jsonmodel_type>;

my constant LINK_LABEL_PROPS = <role relator level identifier display_string description>;


method start {
    my $uri = $!uri;
    nav_message(cmd_prompt() ~ " $!line", :set_default);
    clear_screen;

    $nav_cache = NavCache.new;

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
                    move_nav_cursor(<prev>) || print BEL;
                }
		            when DOWN_ARROW {
                    move_nav_cursor(<next>) || print BEL;
		            }
		            when RIGHT_ARROW {
		                if $y == $y_offset {
			                  print BEL;
		                } else {
			                  @uri_history.push: $uri;
			                  $uri = $nav_cache.uri($current_uri).selected_ref.uri;
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
	          my $selected = $nav_cache.uri($current_uri).selected_ref;
	          given $c {
		            when ' ' {
                    page(pretty client.get($selected.uri,
                                           to_resolve_params(@resolves)));
		            }
		            when "\r" {
                    page(stripped pretty client.get($selected.uri,
                                                    to_resolve_params(@resolves)));
		            }
		            when 'e' {
		                plot_edit($selected.uri, @resolves) || ($message = "No record for $uri");
		                get_char;
		                plot_uri($uri, @resolves) || ($message = "No record for $uri");
		            }
		            when 'r' {
		                if @resolves.grep(%current_refs{$y-$y_offset}) {
			                  @resolves = @resolves.grep: { $_ ne %current_refs{$y-$y_offset} };
		                } else {
			                  @resolves.push(%current_refs{$y-$y_offset});
		                }
                    $nav_cache.remove($current_uri);
		                $new_uri = True;
		            }
		            when 't' {
                    $show_tree = !$show_tree;
                    plot_uri($current_uri);
                }
		            when '.' {
                    print_tree_page(<next>);
                }
		            when ',' {
                    print_tree_page(<prev>);
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
    $current_uri = Str.new;
    last_uris(map { $_.uri }, $nav_cache.uri($current_uri).refs);
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
    if $row <= $term_lines {
        cursor($col, $row);
        $term_cols ||= q:x/tput cols/.chomp.Int; # find the number of columns
        $term_lines ||= q:x/tput lines/.chomp.Int; # find the number of lines

        my $out = visible_trim($s, $term_cols - $col);
        print $out;
        if $fill {
            print ' ' x ($term_cols - visible_length($out));
        }
    }
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

sub print_nav_cursor {
    print_at(ansi('>>', 'bold'), $nav_cursor_col, cursor_position());
    True;
}

sub move_nav_cursor($direction) {
    my $old_cursor = cursor_position();

    if $nav_cache.uri($current_uri).move_focus($direction) {
        print_at('  ', $nav_cursor_col, $old_cursor);
        print_nav_cursor;
    }
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

sub cursor_reset(Int :$line = 1, :$mark) {
    if $mark {
        $cursor_line = %cursor_marks{$mark};
    } else {
        $cursor_line = $line;
    }
}

sub current_cursor {
    $cursor_line;
}

sub cursor_next {
    $cursor_line++;
}

sub cursored_print($s, Int :$indent = 1, Bool :$fill) {
    print_at($_, $indent, $cursor_line++, :$fill) for $s.split("\n");
}

sub mark_cursor($key) {
    %cursor_marks{$key} = $cursor_line;
}

sub cursor_mark($key) {
    %cursor_marks{$key};
}

sub plot_header(%json) {
    cursor_reset(:line(2));

    cursored_print(record_context(%json), :indent(1));
    cursored_print('', :fill);
    cursored_print(ansi(record_label(%json).Str, 'bold'), :indent(4));
    cursored_print('', :fill);
    cursored_print(record_summary(%json), :indent(4), :fill);
    mark_cursor('bottom_of_header');
}

sub print_tree_page($page?) {
    return unless $show_tree;
    my $curi = $nav_cache.uri($current_uri);
    return unless $curi && $curi.children;

    if (given $page {
        when /^ \d+ $/ { $curi.tree_page = $page.Int; }
        when <prev>    { $curi.prev_tree_page; }
        when <next>    { $curi.next_tree_page; }
        when <first>   { $curi.tree_page(1); }
        when <last>    { $curi.last_tree_page; }
        default        { $curi.tree_page; }
       }) {
        cursor_reset(:mark(<top_of_tree>));
        cursored_print($curi.render_tree_page, :indent($tree_indent), :fill(True));
        print_nav_cursor;
    } else {
        print BEL; 
    }
}

sub plot_tree(%json) {
    cursor_reset(:mark('bottom_of_header'));
    cursor_next;
    mark_cursor('top_of_tree');

    if $show_tree {
        if (%json<tree>:exists) {
            if %json<tree><_resolved><child_count> > 0 {
                my $curi = $nav_cache.uri(%json<uri>);

                unless $curi.child_count {
                    $curi.child_count = %json<tree><_resolved><child_count>;
                    my @tree = %json<tree><_resolved><precomputed_waypoints>.values.first.values.first.List;
                    my %width;
                    for <level child_count identifier> -> $prop { %width{$prop} = @tree.map({(($_{$prop} || '').chars, 2).max}).max }
                    for @tree -> $c {
                        if $c {
                            my $level_fmt = ansi("%-{%width<level>}s", 'yellow');
                            my $id_fmt = ansi("%-{%width<identifier>}s", 'green');
                            my $count_fmt = ansi("%{%width<child_count> + 1}s", 'cyan');
                            my $s = sprintf("$count_fmt  $level_fmt  $id_fmt  %s",
                                            $c<child_count> ?? '+' ~ $c<child_count>.Str !! '--',
                                            $c<level>,
                                            $c<identifier> || '--',
                                            $c<title>.substr(0, 100));
                            $curi.add_child($c<uri>, $s);
                        }
                    }
                }
                cursored_print($curi.render_tree_page, :indent($tree_indent), :fill(True));
            } else {
                cursored_print(ansi('-- no children --', 'yellow'), :indent($tree_indent));
            }
        } else {
            cursored_print(ansi('-- no tree --', 'yellow'), :indent($tree_indent));
        }
    }

    cursor_next;
    mark_cursor('top_of_nav');
}

sub plot_uri(Str $uri, @args = (), Bool :$reload) {
    my %json;
    if $nav_cache.is_cached($uri) && !$reload {
        %json = $nav_cache.uri($uri).json;
    } else {
	      nav_message("getting $uri ...");
	      my $raw_json = client.get($uri, to_resolve_params(@args));
	      nav_message("parsing $uri ...");
	      %json = from-json $raw_json;
	      return False if %json<error>:exists;

        $nav_cache.add_uri($uri, :json(%json.clone));

	      nav_message(:default);
    }

    $current_uri = $uri;

    nav_message("plotting $uri ...");
    $term_cols = q:x/tput cols/.chomp.Int; # find the number of columns
    $term_lines = q:x/tput lines/.chomp.Int; # find the number of lines
    run 'tput', 'civis';                   # hide the cursor
    clear_screen;

    plot_header(%json);

#    @uris.push(uri_hash($uri, 'top', ansi($uri, 'bold'), 4, ''));

    plot_tree(%json);

    $y = current_cursor;

    map_refs(%json, 'top', 6);

    $nav_cache.uri($current_uri).refs_page_size($term_lines - cursor_mark(<top_of_nav>) - 2);
    $nav_cache.uri($current_uri).tree_page_size(10);

    plot_nav_page;

    print_nav_cursor;

    $x = 2;
    cursor($x, $y);
    run 'tput', 'cvvis'; # show the cursor
    nav_message(:default);
}

# return the y value of the cursor position for the currently plotted uri
sub cursor_position {
    if my $cached = $nav_cache.uri($current_uri) {
        if $cached.focus_section eq <tree> {
            if $show_tree {
                cursor_mark(<top_of_tree>) + $cached.focus_position;
            } else {
                cursor_mark(<top_of_nav>);        
            }
        } else {
            cursor_mark(<top_of_nav>) + $cached.focus_position;
        }
    } else {
        cursor_mark(<top_of_nav>);        
    }
}

# not needed - see selected_ref in navcache
sub uri_for($cursor) {
    if my $cached = $nav_cache.uri($current_uri) {
        if $show_tree && $cursor < cursor_mark(<top_of_nav>) {
            $cursor - cursor_mark(<top_of_tree>);

        } else {
            $cursor - cursor_mark(<top_of_nav>);
        }
    } else {
        False;
    }
}

sub map_refs(%hash, $parent, $indent) {
    return if $parent eq <top> && $nav_cache.uri(%hash<uri>).refs;

    my $found_ref = 0;
    for %hash.keys.sort: { %hash{$^a}.WHAT ~~ Str ?? -1 !! 1 } -> $prop {
	      my $val = %hash{$prop};
	      if $prop eq 'ref' || $prop eq 'record_uri' || ($parent eq 'results' && $prop eq 'uri') {
	          plot_ref($val, %hash, $parent, $indent);
	          $found_ref = 1;
	      } elsif $val.WHAT ~~ Hash {
	          map_refs($val, $prop, $indent+$found_ref);
	      } elsif $val.WHAT ~~ Array {
	          for $val.values -> $h {
		            last if $y >= $term_lines;
		            if $h.WHAT ~~ Hash {
		                map_refs($h, $prop, $indent+$found_ref);
		            }
	          }
	      }
    }
}


sub plot_ref($uri, %hash, $parent, $indent) {
    my $link_label = link_label($parent, %hash);
    my $s = sprintf("%-*s %s", $nav_cursor_col - 5, $uri, $link_label);
    $nav_cache.uri($current_uri).add_ref($uri, $s);
}


sub plot_nav_page {
    cursor_reset(:mark('top_of_nav'));

    cursored_print($nav_cache.uri($current_uri).render_refs_page(), :indent($tree_indent), :fill(True));
}
    

sub record_context(%hash) {
    my $out;
    $out = ansi(%hash<repository>:exists ?? repo_map(%hash<repository><ref>.split('/')[*-1], :invert) !! 'GLOBAL', 'green');

    for %hash<ancestors>.List.reverse -> $a {
        $out ~= ' > ' ~ ansi($a<level>, 'yellow') if $a<level>;
    }

    $out ~= ' > ' ~ ansi(%hash<level>, 'bold yellow') if %hash<level>;

    if %hash<tree> {
        my %tree = from-json client.get(%hash<uri> ~ (%hash<uri> ~~ /resource/ ?? '/tree/root' !! '/tree/node'));
        if %tree<child_count> > 0 {
            $out ~= ' > ' ~ ansi(%tree<child_count> ~ (%tree<child_count> == 1 ?? ' child' !! ' children'), 'yellow');
        }
        %hash<tree><_resolved> = %tree;
    }

    $out;
}


sub record_id(%hash) {
    my $id = RECORD_ID_PROPS.map({%hash{$_}}).grep(Cool)[0];

    if %hash<id_0> {
        $id = <id_0 id_1 id_2 id_3>.map({%hash{$_}}).grep(Cool).join('.');
    }

    $id && '[' ~ $id ~ ']';
}

sub record_label(%hash) {
    my $label = (RECORD_LABEL_PROPS.map: {%hash{$_}}).grep(Cool)[0];
    $label ~~ s:g/'<' .+? '>'// if $label;
    $label = (record_id(%hash), $label).grep(Cool).join(' ');
    $label;
}

sub badge($label, $background) {
    ansi(' ' ~ $label ~ ' ', 'white on_' ~ $background);
}

sub record_summary(%hash) {
    my @badges;
    @badges.push(badge(%hash<jsonmodel_type>, '0,0,180'));
    @badges.push(badge('public', '0,127,0')) if %hash<publish>;
    @badges.push(badge('restricted', '127,127,0')) if %hash<restrictions_apply>;
    @badges.push(badge('suppressed', '127,0,0')) if %hash<suppressed>;

    %hash.keys.sort.grep({%hash{$_} ~~ Array && %hash{$_} > 0}).map({
	      @badges.push(badge($_ ~ ': ' ~ %hash{$_}.elems, '127,47,95'));
    });

    my $cols = term_cols();
    my $out = @badges.shift;
    my $current_length = visible_length($out);

    for @badges -> $b {
        if $current_length + visible_length($b) + 1 > $cols - 6 {
            $out ~= "\n" ~ $b;
            $current_length = 0;
        } else {
            $out ~= " " ~ $b;
        }
        $current_length += visible_length($b) + 1;
    }

    $out;
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


sub print_nav_help($s) {
    cursored_print(" $s", :indent($term_cols - 50), :fill);
}


sub nav_help {
    run 'tput', 'civis'; # hide the cursor
    cursor_reset;
    print_nav_help('');
    print_nav_help(ansi('UP', 'bold') ~ '/' ~ ansi('DOWN', 'bold') ~ '  Select Previous/Next uri');
    print_nav_help(ansi('LEFT', 'bold') ~ '     Back to last uri');
    print_nav_help(ansi('RIGHT', 'bold') ~ '    Load selected uri');
    print_nav_help(ansi('SPACE', 'bold') ~ '    View json for selected uri');
    print_nav_help(ansi('RETURN', 'bold') ~ '   View summary for selected uri');
    print_nav_help(ansi('t', 'bold') ~ '        Toggle tree view');
    print_nav_help(ansi('r', 'bold') ~ '        Resolve refs like the selected uri');
    print_nav_help(ansi('q', 'bold') ~ '        Quit navigator');
    print_nav_help(ansi('h', 'bold') ~ '        This help');
    print_nav_help('');
    print_nav_help(ansi('    <ANY KEY> to exit help', 'bold'));
    print_nav_help('');
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
	          my $left = $line.index(':') || $line.index('"') || 10;
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
