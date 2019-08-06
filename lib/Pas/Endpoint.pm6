use Config;
use Pas::Logger;
use Pas::ASClient;

use JSON::Tiny;


class Pas::Endpoint {
    has Config $.config;
    has Pas::Logger $.log;
    has Pas::ASClient $.client;

    has Array @!epts;
    
    my constant LOGOUT_URI     = '/endpoints';

    method client { $!client ||= Pas::ASClient.new(:config($!config)); }
    method log { $!log ||= Pas::Logger.new(:config($!config)); }

    method get_or_moan(Bool :$force) {
	return @!epts if @!epts && !$force;
    
	my $e = client.get(ENDPOINTS_URI).trim;
	if $e ~~ /^ <-[{[]> / {
	    say 'No endpoints endpoint!';
	    @TAB_TARGETS = [];
	    #	@TAB_TARGETS = |Command.actions;
	    return [];
	}
	$e = from-json $e;
	@ENDPOINTS = $e ~~ Array ?? $e.unique !! [];
	@TAB_TARGETS = |@ENDPOINTS;
	#    @TAB_TARGETS = |@ENDPOINTS, |Command.actions;
	@ENDPOINTS;
    }


    method targets(Str $match) {
	grep { .Hash } @!epts;
    }

}


