unit module JSONPretty;

grammar Grammar {
    token TOP       { \s* <value> \s*          }
    rule object     { '{' ~ '}' <pairlist>     }
    rule pairlist   { <pair> * % \,            }
    rule pair       { <string> ':' <value>     }
    rule emptyarray { '[]'                     }
    rule array      { '[' ~ ']' <arraylist>    }
    rule arraylist  { <arrayvalue> * % [ \, ]  }
    rule arrayvalue { <value>                  }

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


class PrettyActions {
    has Int $.step = 2;
    has Str $.select;

    method indent(Str $json) {
    	my Int $indent = 0;
	    my Str $out = '';
      my Int $selected = 0;
      my $sel = $!select;
	    for $json.split("\n")>>.trim -> $line {
	        next unless $line ~~ /./;

	        $indent -= $!step if $line ~~ /^<[ \} \] ]>/;
          $out ~= ' ' x ($indent - $selected) ~ $line ~ "\n" if !$!select || $selected;
	        $indent -= $!step if $line eq '[],';
	        $indent += $!step if $line ~~ /^<[ \{ \[ ]>/;

          if $!select {
              if $line ~~ /^ \s* '"' $sel '":'/ {
                  $selected = $indent;
              } elsif $indent <= $selected {
                  $selected = 0;
              }
          }
	    }
      $out ~~ s/ ',' \n $/\n/ if $!select;
	    $out;
    }

    method TOP ($/)        { make self.indent($<value>.made)                  }
    method object($/)      { make "\n" ~ '{' ~ "\n" ~ $<pairlist>.made ~ '}'  }
    method pairlist($/)    { make $<pair>>>.made.join(",\n") ~ "\n"           }
    method pair($/)        { make $<string> ~ ': ' ~ $<value>.made            }
    method emptyarray($/)  { make '[]'                                        }
    method array($/)       { make "\n" ~ '[' ~ "\n" ~ $<arraylist>.made ~ ']' }
    method arraylist($/)   { make $<arrayvalue>>>.made.join(",\n") ~ "\n"     }
    method arrayvalue($/)  { make $<value>.made                               }

    method value:sym<number>($/)      { make +$/.Str            }
    method value:sym<string>($/)      { make $<string>          }
    method value:sym<true>($/)        { make 'true'             }
    method value:sym<false>($/)       { make 'false'            }
    method value:sym<null>($/)        { make 'NULL'             }
    method value:sym<object>($/)      { make $<object>.made;    }
    method value:sym<emptyarray>($/)  { make $<emptyarray>.made }
    method value:sym<array>($/)       { make $<array>.made      }
}


our sub prettify($json, $indent, $select) {
    Grammar.parse($json, :actions(PrettyActions.new(step => $indent, select => $select))).made;
}
