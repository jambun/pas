use NavCache;
use Functions;
use Terminal::ANSIColor;
use JSON::Tiny;

unit class Navigation;
has $.uri;
has @.args;
has $.line;

my Int $nav_cursor_col = 1;

my $current_uri;
my @resolves;
my Str $default_nav_message;
my Str $nav_message;
my Int $current_nav_offset = 0;
my Bool $show_tree = False;
my Int $cursor_line = 1;
my %cursor_marks;
my $nav_cache;
my $tree_indent = 6;
my $last_focus_row;

my constant UP_ARROW    =  "\x[1b][A";
my constant DOWN_ARROW  =  "\x[1b][B";
my constant RIGHT_ARROW =  "\x[1b][C";
my constant LEFT_ARROW  =  "\x[1b][D";
my constant BEL         =  "\x[07]";

my constant RECORD_ID_PROPS = <id_0 component_id digital_object_id>;

my constant RECORD_LABEL_PROPS = <long_display_string display_string title name
                                  last_page outcome_note jsonmodel_type>;

my constant LINK_LABEL_PROPS = <role relator level identifier display_string description>;

sub cached_uri { $nav_cache.uri($current_uri) }

method start {
    my $uri = $!uri;
    nav_message(cmd_prompt() ~ $!line, :set_default);
    clear_screen;

    $nav_cache = NavCache.new(:show_tree($show_tree));

    my Bool $new_uri = True;
    my $c = '';
    my @uri_history = ();
    my $message = '';
    @resolves = @!args || ();

    run 'tput', 'civis';                   # hide the cursor

    while $c ne 'q' {
	      if $new_uri {
	          plot_uri($uri, @resolves) || ($message = "No record for $uri") && last;
	          print_at('.' x @uri_history, 2, 1);
	          print_at(ansi('h', 'bold') ~ 'elp ' ~ ansi('q', 'bold') ~ 'uit',
		                 term_cols() - 9, 1);
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
			              @uri_history.push: $uri;
			              $uri = cached_uri().selected_ref.uri;
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
	          my $selected = cached_uri().selected_ref;
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
                    my $prop = cached_uri().selected_ref.property;
		                if @resolves.grep($prop) {
			                  @resolves = @resolves.grep: { $_ ne $prop };
		                } else {
			                  @resolves.push($prop);
		                }
                    $nav_cache.remove($current_uri);
		                $new_uri = True;
		            }
                when 't' {
                    $nav_cache.show_tree = $show_tree = !$show_tree;
                    $new_uri = True;
                }
		            when '.' {
                    print_section_page(<next>);
                }
		            when ',' {
                    print_section_page(<prev>);
                }
		            when 'h' {
		                nav_help;
		                $new_uri = True;
		            }
	          }
	      }
    }
    nav_message(' ');
    clear_screen;
    cursor(0, q:x/tput lines/.chomp.Int);
    if $nav_cache.is_cached($current_uri) {
        last_uris(map { $_.uri }, cached_uri().section(<refs>).items);
    }
    $current_uri = Str.new;
    $nav_cache.clear;
    run 'tput', 'cvvis'; # show the cursor
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
    if $row <= term_lines() {
        cursor($col, $row);

        my $out = visible_trim($s, term_cols() - $col);
        print $out;
        if $fill {
            print ' ' x (term_cols() - visible_length($out) - $col);
        }
    }
}


sub nav_message(Str $message = '', Bool :$default, Bool :$set_default) {
    $default_nav_message ||= '';
    $nav_message = $message if $message;
    $default_nav_message = $message if $set_default;
    $nav_message = $default_nav_message if $default;
    print_at(sprintf("%-*s", term_cols() - 1, $nav_message), 0, term_lines());
}


sub clear_screen {
    print state $ = qx[clear];
    nav_message;
}

sub print_nav_cursor {
    if $last_focus_row && $last_focus_row !== cached_uri().focus_row {
        print_at('  ', $nav_cursor_col, $last_focus_row);
    }
    print_at(ansi("\x25ac\x25b6", '255,200,120'), $nav_cursor_col, cached_uri().focus_row);
    print_at('Selected uri: ' ~ ansi(cached_uri().selected_ref.uri, '255,200,120'), 1, term_lines() - 1, :fill);
    $last_focus_row = cached_uri().focus_row;
}

sub move_nav_cursor($direction) {
    if cached_uri().move_focus($direction) {
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
    mark_cursor('top_of_header');

    my $title = ansi(record_label(%json).Str, 'bold');

    cached_uri.section(<title>).start_row = cursor_mark(<top_of_header>) + 2;
    cached_uri.section(<title>).add_item(CachedRef.new(:uri($current_uri), :label($title))) unless cached_uri.section(<title>).items;

    cursored_print(record_context(%json), :indent(1));
    cursored_print('', :fill);
    cursored_print(cached_uri.section(<title>).render, :indent(4));
    cursored_print('', :fill);
    cursored_print(record_summary(%json), :indent(4), :fill);
    mark_cursor('bottom_of_header');
}

sub print_section_page($page?) {
    return unless $show_tree;
    my $curi = cached_uri();
    return unless $curi;

    my $sect = $curi.focussed_section;

    if $sect !~~ PagedSection || !$sect.total_size {
        print BEL;
        return;
    }

    if (given $page {
        when /^ \d+ $/ { $sect.page($page.Int); }
        when <prev>    { $sect.prev_page; }
        when <next>    { $sect.next_page; }
        when <first>   { $sect.page(1); }
        when <last>    { $sect.last_page; }
        default        { $sect.page; }
       }) {
        if ensure_page() {
            cursor_reset(:line($sect.start_row));
            cursored_print($sect.render, :indent($tree_indent), :fill);
            print_nav_cursor;
        } else {
            print BEL; 
        }
    } else {
        print BEL; 
    }
}

sub ensure_page {
    my $curi = cached_uri();
    my $sect = $curi.focussed_section;

    # this assumes sequential paging from start - ideally we'd do this for end_index too
    unless $sect.items[$sect.start_index] {
        if $sect.label eq <children> {
            my %args = offset => ($sect.start_index / $curi.json<tree><_resolved><waypoint_size>).floor;

            if $curi.json<jsonmodel_type> eq <archival_object> {
                %args<parent_node> = $current_uri;
            }

            my $resp = from-json client.get($curi.json<resource><ref> ~ '/tree/waypoint', %args);

            if $resp<error> {
                nav_message("Failed to load waypoint: {$resp<error>}");
                return False;
            }

            add_children_for_waypoint(@$resp);
        } else {
            # oh dear - duck and cover!
            nav_message("Don't know how to ensure page for: {$sect.label}");
            return False;
        }
    }
    True;
}

sub add_children_for_waypoint(@waypoint) {
    my %width;
    for <level child_count identifier> -> $prop { %width{$prop} = @waypoint.map({(($_{$prop} || '').chars, 2).max}).max }
    my $title_width = term_cols() - ($tree_indent + (%width.values.reduce: &infix:<+>) + 7);
    for @waypoint -> $c {
        my $level_fmt = ansi("%-{%width<level>}s", 'yellow');
        my $id_fmt = ansi("%-{%width<identifier>}s", 'green');
        my $count_fmt = ansi("%{%width<child_count> + 1}s", 'cyan');
        my $title = $c<title> || ($c<dates> ?? ($c<dates>.head<expression> || ($c<dates>.head<begin> ~ ($c<dates>.head<end> ?? " -- {$c<dates>.head<end>}" !! ''))) !! '-- no title --');
        my $s = sprintf("$count_fmt  $level_fmt  $id_fmt  %s",
                        $c<child_count> ?? '+' ~ $c<child_count>.Str !! '--',
                        $c<level>,
                        $c<identifier> || '--',
                        $title.substr(0, $title_width));
        cached_uri().section(<children>).add_item(CachedRef.new(:label($s), :uri($c<uri>)), :position($c<position>));
    }
}

sub plot_tree(%json) {
    cursor_reset(:mark(<bottom_of_header>));
    cursor_next;
    mark_cursor(<top_of_tree>);

    if $show_tree {
        if (%json<tree>:exists) {
            my $curi = $nav_cache.uri(%json<uri>);

            resolve_tree(%json);

            $curi.json = %json;

            if %json<tree><_resolved><parents> {
                mark_cursor(<top_of_parents>);
                unless $curi.section(<parents>).size {
                    my $level_width = %json<ancestors>.map({$_<level>.chars}).max;
                    $level_width += 3 if %json<ancestors> > 1;
                    for %json<tree><_resolved><parents>.kv -> $ix, $p {
                        my $uri = $p<node> || $p<root_record_uri>;
                        my $level = %json<ancestors>.grep({$_<ref> eq $uri}).head<level>;
                        my $label = (' ' x $ix * 3) ~ ($ix ?? "\x2517\x2501 " !! " \x25fc ") ~ ansi($level, 'yellow') ~ ' ' x ($level_width - $level.chars - $ix * 3) ~ '  ' ~ $p<title>;
                        $curi.add_item(<parents>, $uri, $label);
                    }
                }
                cached_uri.section(<parents>).start_row = cursor_mark(<top_of_parents>);
                cached_uri.section(<parents>).show_header = True;
                cursored_print($curi.section(<parents>).render, :indent(6));
                cursored_print('', :indent(6), :fill);
            }

            if %json<tree><_resolved><child_count> > 0 {
                mark_cursor(<top_of_children>);

                cached_uri.section(<children>).start_row = cursor_mark(<top_of_children>);

                unless $curi.section(<children>).item_count {
                    $curi.section(<children>).item_count = %json<tree><_resolved><child_count>;
                    my @tree = %json<tree><_resolved><precomputed_waypoints>.values.first.values.first.List;

                    add_children_for_waypoint(@tree);
                }
            }
            cursored_print($curi.section(<children>).render, :indent($tree_indent), :fill);
        } else {
            cursored_print(ansi('no tree', 'cyan'), :indent($tree_indent));
        }
    }

    cursor_next;
    mark_cursor(<top_of_nav>);
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
    clear_screen;

    resolve_tree(%json) if $show_tree;

    plot_header(%json);
    plot_tree(%json);
    map_refs(%json, 'top');

    cached_uri().section(<refs>).page_size(term_lines() - cursor_mark(<top_of_nav>) - 2);

    plot_nav_page;
    print_nav_cursor;
    nav_message(:default);
    True;
}

sub map_refs(%hash, $parent, :$depth = 0, :$seq, :@path) {
    return if $parent eq <top> && cached_uri().section(<refs>).items;

    my $found_ref = 0;
    for %hash.keys.sort: { %hash{$^a}.WHAT ~~ Str ?? -1 !! 1 } -> $prop {
	      my $val = %hash{$prop};
	      if $prop eq 'ref' || $prop eq 'record_uri' || ($parent eq 'results' && $prop eq 'uri') {
	          plot_ref($val, %hash, $parent, $depth, :path(@path));
	          $found_ref = 1;
	      } elsif $val.WHAT ~~ Hash {
	          map_refs($val, $prop, :depth($depth+$found_ref), :path((@path, $prop => 0).flat));
	      } elsif $val.WHAT ~~ Array {
	          for $val.kv -> $ix, $h {
		            if $h.WHAT ~~ Hash {
		                map_refs($h, $prop, :depth($depth+$found_ref), :path((@path, $prop => $ix).flat));
		            }
	          }
	      }
    }
}


sub link_label($prop, %hash) {
    my $label = ansi($prop, 'yellow');
    LINK_LABEL_PROPS.map: { $label ~= ': ' ~ ansi(%hash{$_}, 'green') if %hash{$_} }
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


sub plot_ref($uri, %hash, $parent, $depth, :@path) {
    my $link_label = ('  ' x $depth) ~ link_label($parent, %hash);
    cached_uri().add_item(<refs>, $uri, $link_label, $parent, :sort(@path.map({sprintf("%-50s %10d", $_.key, $_.value)})));
}


sub plot_nav_page {
    cursor_reset(:mark('top_of_nav'));
    cached_uri.section(<refs>).start_row = cursor_mark(<top_of_nav>);
    cursored_print(cached_uri().section(<refs>).render(), :indent($tree_indent), :fill);
}

sub resolve_tree(%hash) {
    my %tree;
    if %hash<tree> {
        unless %hash<tree><_resolved> {
            %tree = from-json client.get(%hash<uri> ~ (%hash<jsonmodel_type> eq <resource> ?? '/tree/root' !! '/tree/node'));
            unless %hash<jsonmodel_type> eq <resource> {
                my $id =  %hash<uri>.split('/').tail;
                %tree<parents> = (from-json client.get(%hash<resource><ref> ~ '/tree/node_from_root', ['node_ids[]=' ~ $id])){$id};
            }
            %hash<tree><_resolved> = %tree;
        }
        return %hash<tree><_resolved>;
    }

    %tree;
}    

sub record_context(%hash) {
    my $out;
    $out = ansi(%hash<repository>:exists ?? repo_map(%hash<repository><ref>.split('/')[*-1], :invert) !! 'GLOBAL', 'green');

    for %hash<ancestors>.List.reverse -> $a {
        $out ~= ' > ' ~ ansi($a<level>, 'yellow') if $a<level>;
    }

    $out ~= ' > ' ~ ansi(%hash<level>, 'bold yellow') if %hash<level>;

    my %tree = resolve_tree(%hash);

    if %tree && %tree<child_count> > 0 {
        $out ~= ' > ' ~ ansi(%tree<child_count> ~ (%tree<child_count> == 1 ?? ' child' !! ' children'), 'yellow');
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

    %hash.keys.sort.grep({%hash{$_} ~~ Hash || %hash{$_} ~~ Array && %hash{$_} > 0}).map({
	      @badges.push(badge($_ ~ (%hash{$_} ~~ Array ?? ': ' ~ %hash{$_}.elems !! ''), '127,47,95'));
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


sub print_nav_help($s) {
    cursored_print(" $s", :indent(term_cols() - 50), :fill);
}


sub nav_help {
    cursor_reset;
    print_nav_help('');
    print_nav_help(ansi('UP', 'bold') ~ '/' ~ ansi('DOWN', 'bold') ~ '  Select Previous/Next uri');
    print_nav_help(ansi('<', 'bold') ~ '        Previous page of current section');
    print_nav_help(ansi('>', 'bold') ~ '        Next page of current section');
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
	      if $line.chars > term_cols()-2 {
	          my $left = $line.index(':') || $line.index('"') || 10;
	          my $offset = term_cols();
	          while $offset < $line.chars {
		            my $off = $line.substr(0, $offset).rindex(' ') || $offset;
		            $off += 1 unless $off == $offset;
		            $line.substr-rw($off, 0) = "\n" ~ ' ' x $left;
                last if $line.chars - ($offset + ("\n" ~ ' ' x $left).chars) < term_cols()-2;
		            $offset = $off + (term_cols()-2);
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
