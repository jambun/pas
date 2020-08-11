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

    rule  uricmd        { <uri> <pairlist> <action>? <redirect>? }
    rule  actioncmd     { <action> <arglist> <redirect>? }

    token uri           { '/' <[\/\w]>* }
    rule  pairlist      { <pairitem>* }
    rule  pairitem      { <pair> }
    token pair          { <arg> '=' <value> }
    token action        { <type=.arg> ('.' <qualifier=.arg>)? }
#    token qualifier     { \w+ }
#    token action        { \w+ }
    rule  arglist       { <argitem>* }
    rule  argitem       { <arg> }
    token arg           { \w+ }
    token value         { [ <str> | <singlequoted> | <doublequoted> ] }
    token str           { <-['"\\\s]>+ }
    token singlequoted  { "'" ~ "'" <-[']>* }
    token doublequoted  { '"' ~ '"' <-["]>* }

    rule  redirect      { '>' <file> }
    token file          { <[\w/\.\-]>+ }
}

class Actions {
    method TOP($/)        { make $<uricmd> ?? $<uricmd>.made !! $<actioncmd>.made }

    method uricmd($/)     { make { uri => $<uri>.made,
                                   qualifier => $<action>[0]<qualifier>.made,
                                   args => $<pairlist>.made,
                                   action => ($<action>.made || 'show'),
                                   redirect => $<redirect>.made } }

    method actioncmd($/)  { make { action => $<action>.made,
                                   qualifier => $<action>[0]<qualifier>.made,
                                   args => $<arglist>.made,
                                   redirect => $<redirect>.made } }

    method uri($/)        { make $/.Str }
    method pairlist($/)   { make $<pairitem>>>.made }
    method pairitem($/)   { make $<pair>.made }
    method pair($/)       { make $/.Str }
    method action($/)     { make $/<type>.made }
    method qualifier($/)  { make $/.Str }
    method arglist($/)    { make $<argitem>>>.made }
    method argitem($/)    { make $<arg>.made }
    method arg($/)        { make $/.Str }
    method redirect($/)   { make $<file>.made }
    method file($/)       { make $/.Str }
}


our sub parse($cmd) {
    Grammar.parse($cmd, :actions(Actions.new)).made;
}
