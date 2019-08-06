use XML;

unit module XMLPretty;

class PrettyActions {
    has Int $.step = 2;

    has Int $!indent = 0;
    
    method indent(Str $json) {
    	my Int $indent = 0;
	my Str $out = '';
	for $json.split("\n")>>.trim -> $line {
	    next unless $line ~~ /./;
	    $indent -= $!step if $line ~~ /^<[ \} \] ]>/;
            $out ~= ' ' x $indent ~ $line ~ "\n";
	    $indent += $!step if $line ~~ /^<[ \{ \[ ]>/;
	}
	$out;
    }

    method TOP ($/)      { make $<root>.made }
#    method root ($/)     { make $<value> }

    method attribute($/) { make $<name> ~ '=' ~ $<value> }

    method child($/) { 	$!indent += $!step; make $<element>; $!indent -= $!step }
    
    method element($/)   {
	make (' ' x $!indent) ~ '<'  ~ $<name> ~ ' ' ~ $<attribute>>>.made.join(' ') ~
	     ($<child> ?? ">\n" ~ $<child>>>.made.join("\n") ~ (' ' x $!indent) ~ '</' ~ $<name> ~ ">\n" !! "/>\n" )
    }
    
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


our sub prettify($xml, $indent) {
    XML::Grammar.parse($xml, :actions(PrettyActions.new(step => $indent))).made;
}

