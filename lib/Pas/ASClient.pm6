use Config;
use Pas::Logger;

use HTTP::UserAgent;
use URI::Encode;
use JSON::Tiny;


class Pas::ASClient {
    has HTTP::UserAgent $!http;
    has Config $.config;
    has Pas::Logger $.log;

    my constant LOGOUT_URI     = '/logout';
    our constant ANON_USER     = 'anon';

    method log { $!log ||= Pas::Logger.new(:config($!config)); }
    method !http { $!http //= HTTP::UserAgent.new(:timeout(10)); }

    method !get_request($url, %header) {
        HTTP::Request.new(:GET($url), |%header);
    }
    
    method !post_request($url, %header, $body?) {
        my $request = HTTP::Request.new(:POST($url), |%header);
        $request.add-content($body) if $body;
        $request;
    }

    method !delete_request($url, %header) {
        HTTP::Request.new(:DELETE($url), |%header);
    }

    method !multipart_request($url, %header, %files is copy) {
        for %files.kv -> $name, $file {
            my ($filename, $type) = $file.split('::');
            unless $filename.IO.e {
                self.log.blurt("File not found: $filename");
                next;
            }
            unless $type {
                if $filename ~~ /\.(<-[.]>+)$/ {
                    $type = 'text/' ~ $0.Str;
                }
            }
            $type ||= 'text/plain';
            my %h = 'Content-Type' => $type;
            %files{$name} = [$file, $file, |%h];
        }
        my $request = HTTP::Request.new(:POST($url), |%header);
        $request.add-form-data(%files, :multipart);
        $request;
    }
    
    method !handle_request($url, %header, $body, %files = {}, Bool :$delete) {
        my $request = $delete ?? self!delete_request($url, %header) !!
                                 %files ?? self!multipart_request($url, %header, %files) !!
                                           $body ?? self!post_request($url, %header, $body) !!
                                                    self!get_request($url, %header);
        self.log.blurt($request.Str);
        self!http.request($request);
    }
    
    method !request($uri, @pairs, $body?, Bool :$delete, Bool :$no_session, Str :$host?) {
        my $url = self.build_url($uri, @pairs, :$host);
        my %header = 'X-ArchivesSpace-Priority' => 'high';
        %header<X-Archivesspace-Session> = $!config.attr<token> if $!config.attr<token> && !$no_session;
        %header<Content-Type> = 'text/json' if $body;

        my %files = (flat @pairs.grep(/'=<<'/).map: { .split('=<<')  }).Hash;

        my $response;
        try {
            $response = self!handle_request($url, %header, $body, %files, :$delete);
            
            CATCH {
                self.log.blurt("Sadly, something went wrong: " ~ .Str);
                self.log.blurt(.backtrace);
                return '{"error": "' ~ .Str ~ '"}' }
        }

        # there's something wrong with the session
        if $response.status-line ~~ /412/ {

            # so try to login again
            self.login;
            %header<X-Archivesspace-Session> = $!config.attr<token> if $!config.attr<token>;

            # and try the request again
            $response = self!handle_request($url, %header, $body, %files, :$delete);
        }
        
        self.log.blurt($response.status-line);

        if $response.status-line ~~ /412/ {
            say 'The session was bad. Tried to login again, but it is still not working.';
            say "Say 'login.prompt' to re-enter login details, or 'session' to find a good session";
        }

        $response.decoded-content;
    }


    method build_url($uri, @pairs is copy, Str :$host?) {
        # remove any file upload pairs
        @pairs = @pairs.grep: {! .Str.comb('=<<')}
        my $url = ($host || $!config.attr<url>) ~ $uri;
        $url ~= '?' ~ @pairs.join('&') if @pairs;
        uri_encode($url);
    }
    

    method post($uri, @pairs, $body) {
        self!request($uri, @pairs, $body);
    }


    method get($uri, @pairs = [], Bool :$no_session, Str :$host?) {
        self!request($uri, @pairs, :$no_session, :$host);
    }


    method get_anon($uri, @pairs = []) {
        self!request($uri, @pairs, :no_session);
    }

    
    method delete($uri) {
        self!request($uri, [], :delete);
    }


    method find_session(Str $name) {
        if $name ~~ /^ \d+ $/ {
            $!config.attr<sessions>.sort[$name.Int - 1].value;
        } else {
            $!config.attr<sessions>{$name};
        }
    }


    # FIXME: this session handling stuff should probably move
    #        to Config, and probably wants a Session class
    method switch_to_session(Str $name) {
        my $sess = self.find_session($name);
        return 'Unknown session: ' ~ $name unless $sess;

        for <url user pass time token> {
            $!config.attr{$_} = $sess{$_}
        }
        $!config.save;
        
        'Switched to session: ' ~ $!config.attr<user> ~ ' on ' ~ $!config.attr<url>;
    }


    method ensure_session {
        if $!config.attr<token> {
            self.add_session;
        } else {
            self.login;
        }
    }


    method add_session {
        $!config.attr<sessions>{$!config.session_key} = {
            url   => $!config.attr<url>,
            user  => $!config.attr<user>,
            pass  => $!config.attr<pass>,
            token => $!config.attr<token>,
            time  => $!config.attr<time>
        };

        $!config.attr<sessions>{$!config.session_key({url => $!config.attr<url>, user => ANON_USER})}<url> = $!config.attr<url>;
        $!config.attr<sessions>{$!config.session_key({url => $!config.attr<url>, user => ANON_USER})}<user> = ANON_USER;

        $!config.save;
    }
    

    method delete_session(Str $name) {
        my %sess = self.find_session($name);
        return 'Unknown session: ' ~ $name unless %sess;

        return "Can't delete current session!" if %sess<token> && %sess<token> eq $!config.attr<token>;

        $!config.attr<sessions>{$!config.session_key(%sess)}:delete;

        # delete anon if it's the only session left for url
        my @sess_keys = grep {.Str.starts-with(%sess<url>)}, $!config.attr<sessions>.keys;
        if @sess_keys.elems == 1 && @sess_keys.head.ends-with(ANON_USER) {
            $!config.attr<sessions>{@sess_keys.head}:delete;
        }

        $!config.save;

        'Deleted session: ' ~ %sess<user> ~ ' on ' ~ %sess<url>;
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
        my $resp     = self!http.request(self!post_request(self.build_url($uri, @pairs), %header));

        if $resp.status-line ~~ /200/ {
            $!config.attr<token> = (from-json $resp.decoded-content)<session>;
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


