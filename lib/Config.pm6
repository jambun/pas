use JSON::Tiny;
use JSONPretty;


class Config {
    has %.attr =
        url  => 'http://localhost:4567',
        user => 'admin',
        pass => 'admin',
	sessions => {};

    has %!prompts =
        url  => 'ArchivesSpace backend URL',
        user => 'Username',
        pass => 'Password';

    has $!file = 'config.json';

    has Str $.dir;


    method load($url, $user, $pass, $token, $prompt) {
        if !$prompt && self.path.IO.e {
            %!attr = from-json slurp(self.path);
            for <url user pass token> { %!attr{$_} = $::($_) if $::($_) }
        } else {
	    self.prompt;
        }
    }


    method prompt(@attrs = <url user pass>) {
	for @attrs { %!attr{$_} = $::($_) || self.prompt_default(%!prompts{$_}, %!attr{$_}) }
    }


    method prompt_default($prompt, $default) {
        my $response = prompt $prompt ~ " (default: {$default}): ";
        $response ~~ /\w/ ?? $response !! $default;
    }


    method set($k, $v) {
        %!attr{$k} = $v;
	self.save;
    }


    method path { $!dir ~ '/' ~ $!file }


    method json {
        JSONPretty::Grammar.parse(to-json(%!attr), :actions(JSONPretty::Actions.new)).made;
    }


    method save {
    	mkdir($!dir);
        spurt self.path, self.json;
    }


}
