use Pas::Store;

use JSON::Tiny;
use JSONPretty;


class Config {
    has %.attr =
    url  => 'http://localhost:4567',
    user => 'admin',
    pass => 'admin',
    sessions => {},
    properties => {};

    has %.prop_defaults =
    loud     => False,
    compact  => False,
    page     => True,
    color    => True,
    time     => False,
    savepwd  => False,
    anon     => False,
    timeout  => 5,
    stamp    => False,
    spool    => True,
    indent   => 2;

    has %!prompts =
    url  => 'ArchivesSpace backend URL',
    user => 'Username',
    pass => 'Password';

    has $!file = 'config.json';

    has Pas::Store $.store;


    method load {
        if $!store.path($!file).IO.e {
            %!attr = from-json $!store.load($!file);
        } else {
            self.prompt;
            self.save;
        }
    }


    method prompt(@attrs = <url user pass>) {
        for @attrs { %!attr{$_} = $::($_) || self.prompt_default(%!prompts{$_}, %!attr{$_}, :pass($_ ~~ /pass/)) }
        %!attr<url> = 'http://localhost:' ~ %!attr<url> if %!attr<url> ~~ /^\d/;
        %!attr<url> = 'http://' ~ %!attr<url> if %!attr<url> !~~ /^http/;
        %!attr<url> = %!attr<url> ~ ':8089' if %!attr<url> !~~ /\d$/;
    }


    method prompt_for($k, $prompt, :$pass, :$no_set) {
        if $no_set {
            self.prompt_default($prompt, %!attr{$k}, :$pass);
        } else {
            %!attr{$k} = self.prompt_default($prompt, %!attr{$k}, :$pass);
        }
    }


    method prompt_default($prompt, $default, :$pass) {
        run 'stty', '-echo' if $pass;
        my $response = prompt $prompt ~ ($default ?? " ({$default}): " !! ': ');
        run 'stty', 'echo' if $pass;
        say "" if $pass;
        $response ~~ /\w/ ?? $response !! $default;
    }


    method prop {
        %!attr<properties>;
    }


    method apply_property_defaults(Bool :$force) {
        for %!prop_defaults.kv -> $k, $v {
            %!attr<properties>{$k} = $v if $force || !(%!attr<properties>{$k}:exists);
        }
    }


    method set($k, $v) {
        %!attr{$k} = $v;
        self.save;
    }


    method json {
        JSONPretty::Grammar.parse(to-json(self.stripped), :actions(JSONPretty::PrettyActions.new)).made;
    }


    method save {
        $!store.save($!file, self.json);
    }

    
    method stripped {
        return %!attr if self.prop<savepwd>;

        my %h = %!attr;

        %h<pass> = '';
        for %h<sessions>.values { $_<pass> = '' }
        %h;
    }


    method session_key(%sess = %!attr) {
        %sess<url> ~ '|' ~ %sess<user>;
    }
}
