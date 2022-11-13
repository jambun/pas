use Config;
use Pas::Logger;

use HTTP::UserAgent;
use URI::Encode;
use JSON::Tiny;
use Terminal::ANSIColor;


class Pas::ASClient {
    has HTTP::UserAgent $!http;
    has Config $.config;
    has Pas::Logger $.log;
    has %.last_response_header;

    my constant LOGOUT_URI     = '/logout';

    method log { $!log ||= Pas::Logger.new(:config($!config)); }
    method !http { $!http //= HTTP::UserAgent.new(:timeout($!config.attr<properties><timeout>)); }

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

    method !multipart_request($url, %header, %files is copy, Bool :$raw?) {
        unless $raw {
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
        }

        my $request = HTTP::Request.new(:POST($url), |%header);
        $request.add-form-data(%files, :multipart);
        $request;
    }
    
    method !handle_request($url, %header, $body, %files = {}, Bool :$delete, Int :$timeout?, :%parts?) {
        my $intime = now;
        my $request = $delete ?? self!delete_request($url, %header) !!
                                 %parts ?? self!multipart_request($url, %header, %parts, :raw) !!
                                 %files ?? self!multipart_request($url, %header, %files) !!
                                           $body ?? self!post_request($url, %header, $body) !!
                                                    self!get_request($url, %header);
        self.log.blurt($request.Str);

        my $resp;
        self!http.timeout = $timeout || $!config.attr<properties><timeout>;
        await Promise.anyof(
            # add a second to give the request a chance to timeout first
            # this timeout is to handle zombies!
            Promise.in(($timeout || $!config.attr<properties><timeout>) + 1),
            start {
                $resp = self!http.request($request);
            });
        say colored(((now - $intime)*1000).Int ~ ' ms', 'cyan') if $!config.attr<properties><time>;
        if ($resp) {
            %!last_response_header = $resp.header.hash;
            self.log.blurt($resp.header);
        }
        $resp;
    }
    
    method !request($uri, @pairs, $body?, Bool :$delete, Bool :$no_session, Str :$host?, Int :$timeout?, :%parts?) {
        my $url = self.build_url($uri, @pairs, :$host);
        my %header = 'X-ArchivesSpace-Priority' => 'high';
        %header<X-Archivesspace-Session> = $!config.attr<token> if $!config.attr<token> && !$no_session && !$!config.attr<properties><anon>;
        %header<Content-Type> = 'text/json' if $body;

        my %files = (flat @pairs.grep(/'=<<'/).map: { .split('=<<')  }).Hash;

        my $response;
        try {
            $response = self!handle_request($url, %header, $body, %files, :$delete, :$timeout, :%parts) || die "Timed out";

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

            try {
                # and try the request again
                $response = self!handle_request($url, %header, $body, %files, :$delete, :$timeout) || die "Timed out";

                CATCH {
                    self.log.blurt("Sadly, something went wrong: " ~ .Str);
                    self.log.blurt(.backtrace);
                    return '{"error": "' ~ .Str ~ '"}' }
            }
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

        # uri_encode drops # and anything after it
        # if a # has got this far we want it - like with solr ids for pui docs
        # so a bit of gross hackery to retain them
        $url ~~ s:g/ '#' /_HASHME_/;
        $url = uri_encode($url);
        $url ~~ s:g/ '_HASHME_' /%23/;

        $url ~~ s:g/ '[' /\%5b/;
        $url ~~ s:g/ ']' /\%5d/;

        $url;
    }
    

    method post($uri, @pairs = [], $body = 'nothing') {
        self!request($uri, @pairs, $body);
    }


    method multi_part($uri, @pairs, %parts) {
        self!request($uri, @pairs, :%parts);
    }


    method get($uri, @pairs = [], Bool :$no_session, Str :$host?, Int :$timeout?) {
        self!request($uri, @pairs, :$no_session, :$host, :$timeout);
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

        $!config.save;
    }
    

    method delete_session(Str $name) {
        my %sess = self.find_session($name);
        return 'Unknown session: ' ~ $name unless %sess;

        return "Can't delete current session!" if %sess<token> && %sess<token> eq $!config.attr<token>;

        $!config.attr<sessions>{$!config.session_key(%sess)}:delete;

        $!config.save;

        'Deleted session: ' ~ %sess<user> ~ ' on ' ~ %sess<url>;
    }


    method login {
        return if $!config.attr<properties><anon>;
        
        self.log.blurt('Logging in to ' ~ $!config.attr<url> ~ ' as ' ~ $!config.attr<user>);

        unless $!config.attr<pass> {
            $!config.prompt_for('pass', 'Enter password for ' ~ $!config.attr<user>, :pass);
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
        # FIXME: probably should switch to another on current host or something else
        #        and what about no sessions left
        # my $user = $!config.attr<user>;
        # self.switch_to_session(ANON_USER);
        # self.delete_session($user);
        $out;
    }
}


