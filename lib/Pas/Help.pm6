use Config;
use Pas::Store;
use Pas::Logger;

use HTTP::UserAgent;
use URI::Encode;
use JSON::Tiny;


class Pas::Help {
    has Str $.topic;
    has Pas::Store $.store;
    has Str $.dir;

    my constant DEFAULT_DIRECTORY = 'help';
    
    method dir {
	$!dir ||= DEFAULT_DIRECTORY;
	if !self!store.path($!dir).IO.e {
	    mkdir self!store.path($!dir);
	}
	$!dir;
    }

    method !store { $!store //= Pas::Store.new(:dir(self.dir)); }

    method file($topic) { self.dir ~ '/' ~ $topic; }
    
    method topic($topic) { self!store.load(self.file($topic), :make); }
    
    method update($topic, $text) { self!store.save(self.file, $text); }
}
