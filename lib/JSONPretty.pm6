use Terminal::ANSIColor;

unit module JSONPretty;

grammar Grammar {
    token TOP       { \s* <value> \s*          }
    rule object     { '{' ~ '}' <pairlist>     }
    rule pairlist   { <pair> * % \,            }
    rule pair       { <string> ':' <value>     }
    rule emptyarray { '[]'                     }
    rule array      { '[' ~ ']' <arraylist>    }
    rule arraylist  { <arrayvalue> * % [ \, ]  }
    rule arrayvalue {  <value>                 }

    proto token value {*};

    token value:sym<number> {
        '-'?
    	[ 0 | <[1..9]> <[0..9]>* ]
    	[ \. <[0..9]>+ ]?
    	[ <[eE]> [\+|\-]? <[0..9]>+ ]?
    }

    token value:sym<true>       { <sym>        }
    token value:sym<false>      { <sym>        }
    token value:sym<null>       { <sym>        }
    token value:sym<object>     { <object>     }
    token value:sym<emptyarray> { <emptyarray> }
    token value:sym<array>      { <array>      }
    token value:sym<string>     { <string>     }

    token string          { \" ~ \" [ <str> | \\ <str=.str_escape> ]*     }
    token str             { <-["\\\t\n]>+                                 }
    token str_escape      { <["\\/bfnrt]> | 'u' <utf16_codepoint>+ % '\u' }
    token utf16_codepoint { <.xdigit>**4                                  }
}


grammar GrammarWithDiff is Grammar {
    rule pair       { <string> ':' [ <diffvalue> | <value> ]     }
    rule arrayvalue { [ <diffvalue> | <value> ] }

    rule diffvalue  { '{' ~ '}' <diffpair>     }
    rule diffpair   { '"_diff":' '[' <fromvalue> ',' <tovalue> ']' }
    token fromvalue { <value> }
    token tovalue   { <value> }
}


class PrettyActions {
    has Int $.step = 2;
    has Str $.select;
    has Bool $.diff_only = False;

    method indent(Str $json) {
    	my Int $indent = 0;
	    my Str $out = '';
      my Int $selected = 0;
      my $sel = $!select;

	    for $json.split("\n")>>.trim -> $line {
	        next unless colorstrip($line) ~~ /./;

          if colorstrip($line) ~~ /^  <[ \} \] ]> / {
	            $indent -= $!step;
          }

          $out ~= ' ' x ($indent - $selected) ~ $line ~ "\n" if !$!select || $selected;

          if colorstrip($line) eq '[],' {
	            $indent -= $!step;
          }

          if colorstrip($line) ~~ /^  <[ \{ \[ ]> / {
	            $indent += $!step;
          }

          if $!select {
              if $line ~~ /^ \s* '"' $sel '":'/ {
                  $selected = $indent;
              } elsif $indent <= $selected {
                  $selected = 0;
              }
          }
	    }
      $out ~~ s/ ',' \n $/\n/ if $!select;

      if $!diff_only {
          my %lines{Int} = $out.split("\n").pairs;
          my %out_lines{Int};

          sub diff_strip(Bool :$reverse) {
              my $found_depth = 0;
              my @ix = %lines.keys.sort;
              @ix = @ix.reverse if $reverse;
              for @ix -> $ix {
                  my $line = %lines{$ix};
                  my $ss = colorstrip($line);
                  $ss ~~ /^ (\s*)/;
                  my $depth = $0.Str.chars;
                  if $ss ne $line {
                      $found_depth = $depth;
                      %out_lines{$ix} = $line;
                  } elsif $depth < $found_depth {
                      $found_depth = $depth;
                      %out_lines{$ix} = $line;
                  } elsif $reverse && $depth == $found_depth && $ss ~~ /^ \s* '"' \w+ '":' $/ {
                      $found_depth = $depth - 1;
                      %out_lines{$ix} = $line;
                  }
              }
          }

          diff_strip();
          diff_strip(:reverse);

          $out = %out_lines.keys.sort.map({ %out_lines{$_}}).join("\n");
      }

	    $out;
    }

    method ansi($text, $fmt) {
        ($text.split("\n").map: { $_ ?? colored($_, $fmt) !! $_ }).join("\n");
    }

    method TOP ($/)        { make self.indent($<value>.made)                  }
    method object($/)      { make "\n" ~ '{' ~ "\n" ~ $<pairlist>.made ~ '}'  }
    method pairlist($/)    { make $<pair>>>.made.join(",\n") ~ "\n"           }
    method pair($/)        { make $<string> ~ ': ' ~ ($<diffvalue>.made || $<value>.made) }
    method emptyarray($/)  { make '[]'                                        }
    method array($/)       { make "\n" ~ '[' ~ "\n" ~ $<arraylist>.made ~ ']' }
    method arraylist($/)   { make $<arrayvalue>>>.made.join(",\n") ~ "\n"     }
    method arrayvalue($/)  { make ($<diffvalue>.made || $<value>.made)        }

    method diffvalue($/)   { make $<diffpair>.made                            }
    method diffpair($/)    { make ($<fromvalue>.made, $<tovalue>.made).grep({$_}).join(' ') } 
    method fromvalue($/)   { make $<value>.made.Str eq 'NULL' ?? False !! self.ansi($<value>.made.Str, 'red') }
    method tovalue($/)     { make $<value>.made.Str eq 'NULL' ?? False !! self.ansi($<value>.made.Str, 'green') }

    method value:sym<number>($/)      { make +$/.Str            }
    method value:sym<string>($/)      { make $<string>          }
    method value:sym<true>($/)        { make 'true'             }
    method value:sym<false>($/)       { make 'false'            }
    method value:sym<null>($/)        { make 'NULL'             }
    method value:sym<object>($/)      { make $<object>.made;    }
    method value:sym<emptyarray>($/)  { make $<emptyarray>.made }
    method value:sym<array>($/)       { make $<array>.made      }
}


our sub prettify($json, Int :$indent, Bool :$mark_diff, Str :$select, Bool :$inline) {
    if $mark_diff {
        GrammarWithDiff.parse($json, :actions(PrettyActions.new(step => $indent, select => $select, :diff_only(!$inline)))).made;
    } else {
        Grammar.parse($json, :actions(PrettyActions.new(step => $indent, select => $select))).made;
    }
}
