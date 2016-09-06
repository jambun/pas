use Config;
use Pas::Logger;

use Net::HTTP::GET;
use Net::HTTP::POST;


class Pas::ASClient {
    has Config $.config;
    has Pas::Logger $.log;

    my constant LOGOUT_URI     = '/logout';
    our constant ANON_USER     = 'anon';

    method log { $!log ||= Pas::Logger.new(:config($!config)); }

    method !request($uri, @pairs, $body?) {
	my $url = self.build_url($uri, @pairs);
	my %header = 'Connection' => 'close';   # << this works around a bug in Net::HTTP

	%header<X-Archivesspace-Session> = $!config.attr<token> if $!config.attr<token>;
    
	self.log.blurt(%header);
	self.log.blurt($url);

	my $response = $body ?? Net::HTTP::POST($url, :%header, :$body) !! Net::HTTP::GET($url, :%header);

	# there's something wrong with the session
	if $response.status-line ~~ /412/ {

	    # so try to login again
            self.login;
	    %header<X-Archivesspace-Session> = $!config.attr<token> if $!config.attr<token>;

	    # and try the request again
       	    $response = $body ?? Net::HTTP::POST($url, :%header, :$body) !! Net::HTTP::GET($url, :%header);
	}
    
	self.log.blurt($response.status-line);

	if $response.status-line ~~ /412/ {
	    say 'The session was bad. Tried to login again, but it is still not working.';
	    say "Say 'login.prompt' to re-enter login details, or 'session' to find a good session";
	}

	$response.body.decode('utf-8');
    }


    method build_url($uri, @pairs) {
	my $url = $!config.attr<url> ~ $uri;
	$url ~= '?' ~ @pairs.join('&') if @pairs;
	# FIXME: escape this properly
	$url ~~ s:g/\s/\%20/;
	$url;
    }
    
    method post($uri, @pairs, $data) {
	my $body = Buf.new($data.ords);
	self!request($uri, @pairs, $body);
    }


    method get($uri, @pairs = []) {
	self!request($uri, @pairs);
    }


    # FIXME: this session handling stuff should probably move
    #        to Config, and probably wants a Session class
    method switch_to_session(Str $name) {
	my $sess = $!config.attr<sessions>{$name};
	return 'Unknown session: ' ~ $name unless $sess;

	for <url user pass time token> {
	    $!config.attr{$_} = $sess{$_}
	}
	$!config.save;
    
	'Switched to session: ' ~ $name;
    }


    method delete_session(Str $name) {
	my $sess = $!config.attr<sessions>{$name};
	return 'Unknown session: ' ~ $name unless $sess;

	return "Can't delete current session!" if $sess<token> eq $!config.attr<token>;

	$!config.attr<sessions>{$name}:delete;
	$!config.save;

	'Deleted session: ' ~ $name;
    }


    method login {
	return if $!config.attr<user> eq ANON_USER;
    
	self.log.blurt('Logging in to ' ~ $!config.attr<url> ~ ' as ' ~ $!config.attr<user>);

	unless $!config.attr<pass> {
	    $!config.prompt_for('pass', 'Enter password for ' ~ $!config.attr<user>);
	}
    
	my $uri      = '/users/' ~ $!config.attr<user> ~ '/login';
	my @pairs    = ["password={$!config.attr<pass>}"];
	my %header   = 'Connection' => 'close';
	my $resp     = Net::HTTP::POST(self.build_url($uri, @pairs), :%header);

	if $resp.status-line ~~ /200/ {
            $!config.attr<token> = (from-json $resp.body.decode('utf-8'))<session>;
	    $!config.attr<time> = time;
	    $!config.attr<sessions>{$!config.attr<user>} = {
		url   => $!config.attr<url>,
		user  => $!config.attr<user>,
		pass  => $!config.attr<pass>,
		token => $!config.attr<token>,
		time  => $!config.attr<time>
	    };
	    $!config.attr<sessions>{ANON_USER} = {
		url   => $!config.attr<url>,
		user  => ANON_USER,
		pass  => '',
		token => '',
		time  => 0
	    };
	    $!config.save;
	    'Successfully logged in to ' ~ $!config.attr<url> ~ ' as ' ~ $!config.attr<user>;
	} else {
	    $!config.attr<token> = '';
            say 'Log in failed!';
	    '';
	}
    }


    method logout {
	my $out = self.post(LOGOUT_URI, [], 'byebye');
	my $user = $!config.attr<user>;
	self.switch_to_session(ANON_USER);
	self.delete_session($user);
	$out;
    }
}


