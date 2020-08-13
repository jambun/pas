# /just/a/uri
# /uri/with/a action
# action
# action arg arg
# action.qual arg
# /uri/with pairs=of args=to pass
# /uri/with quoted='pairs of args' included
# /uri/to/save/to > file

unit module Pas::CommandParser;

grammar Grammar {
    token TOP           { <.ws> [ <uricmd> | <actioncmd> ] <.ws> }

    rule  uricmd        { <uri> <pairlist> <action>? <postfile>? <redirect>? }
    rule  actioncmd     { <action> <arglist> <redirect>? }

    token uri           { '/' <[\/\w]>* }
    rule  pairlist      { <pairitem>* }
    rule  pairitem      { <pair> }
    token pair          { <key=.refpath> '=' <value> }
    token refpath       { <[\w\.\d]>+ }
    token action        { <type=.arg> ('.' <qualifier=.arg>)? }
    rule  arglist       { <argitem>* }
    rule  argitem       { <arg> }
    token arg           { <[\w\d]>+ }
    token value         { [ <str> | <singlequoted> | <doublequoted> ] }
    token str           { <-['"\\\s]>+ }
    token singlequoted  { "'" ~ "'" (<-[']>*) }
    token doublequoted  { '"' ~ '"' (<-["]>*) }

    rule  postfile      { '<' <file> }
    rule  redirect      { '>' <file> }
    token file          { <[\w/\.\-]>+ }
}

class Actions {
    method TOP($/)        { make $<uricmd> ?? $<uricmd>.made !! $<actioncmd>.made }

    method uricmd($/)     { make { line => $/.Str,
                                   uri => $<uri>.made,
                                   qualifier => $<action>[0]<qualifier>.made,
                                   args => $<pairlist>.made,
                                   action => ($<action>.made || 'show'),
                                   postfile => $<postfile>.made,
                                   redirect => $<redirect>.made } }

    method actioncmd($/)  { make { line => $/.Str,
                                   action => $<action>.made,
                                   qualifier => $<action>[0]<qualifier>.made,
                                   args => $<arglist>.made,
                                   redirect => $<redirect>.made } }

    method uri($/)        { make $/.Str }
    method pairlist($/)   { make $<pairitem>>>.made }
    method pairitem($/)   { make $<pair>.made }
    method pair($/)       { make self.pairkey($/<key>) ~ '=' ~ ($/<value><str> || $/<value><singlequoted>[0] || $/<value><doublequoted>[0]).Str }
    method refpath($/)    { make $/.Str }
    method action($/)     { make $/<type>.made }
    method qualifier($/)  { make $/.Str }
    method arglist($/)    { make $<argitem>>>.made }
    method argitem($/)    { make $<arg>.made }
    method arg($/)        { make $/.Str }
    method postfile($/)   { make $<file>.made }
    method redirect($/)   { make $<file>.made }
    method file($/)       { make $/.Str }

    method pairkey($s) {
        given $s {
            when 'p' { 'page' }
            when 'r' { 'resolve[]' }
            when 't' { 'type[]' }
            when 'u' { 'uri[]' }
            default  { $s }
        }
    }
}


our sub parse($cmd) {
    Grammar.parse($cmd, :actions(Actions.new)).made;
}

