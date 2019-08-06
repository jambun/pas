use Config;
use Pas::Logger;

use Net::HTTP::GET;
use Net::HTTP::POST;
use URI::Encode;
use Digest::MD5;
use Crypt::Random;
use JSON::Tiny;


class Pas::ASClient {
    has Config $.config;
    has Pas::Logger $.log;

    my constant LOGOUT_URI     = '/logout';
    our constant ANON_USER     = 'anon';

    method log { $!log ||= Pas::Logger.new(:config($!config)); }

    method !build_multipart(%parts) {
	my $body;
	my $boundary = Digest::MD5.new.md5_hex(crypt_random().Str).substr(0, 32);
#	$boundary = '-----------RubyMultipartPost';
	
	my %bad_parts;
	
	for %parts.kv -> $name, $file {
	    my ($filename, $type) = $file.split('::');
	    unless $filename.IO.e {
		%bad_parts{$name} = $filename;
		next;
	    }
	    unless $type {
		if $filename ~~ /\.(<-[.]>+)$/ {
		    $type = 'text/' ~ $0.Str;
		}
	    }
	    $type ||= 'text/plain';
	    $type = 'text/plain';

	    my $content = slurp($filename);
	    my $content_length = $content.chars;
#	    $body ~= qq:to/END/;
#	    --$boundary
#	    Content-Type: $type; charset="utf-8"
#	    Content-Disposition: form-data; name="$name"; filename="$filename"

#	    {slurp($filename)}
#	    END
	 
	    $body ~= qq:to/END/;
	    --$boundary
	    Content-Disposition: form-data; name="$name"
	    Content-Length: $content_length

	    {slurp($filename)}
	    END
	}
	$body ~= "--$boundary--\n";
	
	say $body;

	return ($boundary, $body, %bad_parts)
    }

    method !request($uri, @pairs_in, $body_in?) {
	my %header = 'X-ArchivesSpace-Priority' => 'high';
	%header<Connection> = 'close';   # << this works around a bug in Net::HTTP
	%header<X-Archivesspace-Session> = $!config.attr<token> if $!config.attr<token>;

	my $body = $body_in;
	my @pairs = @pairs_in;
	my $stream;
        if @pairs.grep(/'=<<'/) {
	    # upload files ...
	    my $boundary;
	    my %bad_parts;
	    ($boundary, $body, %bad_parts) = self!build_multipart((flat @pairs.grep(/'=<<'/).map: { .split('=<<')  }).Hash);
	    if %bad_parts {
		return '{"error": "File not found", "files": ["' ~ %bad_parts.values.join('", "') ~ '"]}';
	    }
	    @pairs = @pairs.grep: {! .Str.comb('=<<')}
	    %header<Content-Type> = "multipart/form-data; boundary=\"$boundary\"";
	    %header<Accept> = '*/*';
	    spurt './body_stream', $body;
	    $stream = True;
	} else {
	    %header<Content-Type> = 'text/json' if $body;
	}
	
	my $url = self.build_url($uri, @pairs);

	self.log.blurt(%header);
	self.log.blurt($url);
	
	my $response;
        try {
	    $response = $stream ?? Net::HTTP::POST($url, :header(%header), :body(open './body_stream')) !!
	    $body ?? Net::HTTP::POST($url, :header(%header), :body($body))
	                      !! Net::HTTP::GET($url, :header(%header));
        
            CATCH {
		self.log.blurt("Sadly, something went wrong: " ~ .Str);
		self.log.blurt(.backtrace);
		return '{"error": "No backend"}'
	    }
        }

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
#	$url ~= '?' ~ (@pairs.map: { $_.subst(/'<=' (<-[<]> .* )/, {'=' ~ slurp($0.Str)})}).join('&') if @pairs;
	uri_encode($url);
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


    method ensure_session {
	if $!config.attr<token> {
	    self.add_session;
	} else {
	    self.login;
	}
    }
    

    method add_session(Str $name = $!config.attr<user>) {
	$!config.attr<sessions>{$name} = {
	    url   => $!config.attr<url>,
	    user  => $!config.attr<user>,
	    pass  => $!config.attr<pass>,
	    token => $!config.attr<token>,
	    time  => $!config.attr<time>
	};
	$!config.attr<sessions>{ANON_USER}<url> = $!config.attr<url>;
	$!config.save;
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
	    self.add_session;
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


