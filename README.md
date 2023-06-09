# pas

An ArchivesSpace commandline client

Needs Raku (Perl6). Currently developing on an M1 Mac against:

    % raku --version
    Welcome to Rakudo™ v2023.04.
    Implementing the Raku® Programming Language v6.d.
    Built on MoarVM version 2023.04.

Dependencies:

    % zef install JSON::Tiny
    % zef install Terminal::ANSIColor
    % zef install HTTP::UserAgent
    % zef install URI::Encode
    % zef install XML
    % zef install Digest::MD5
    % zef install Crypt::Random
    % zef install Base64
    % zef install Linenoise


And an ArchivesSpace [plugin](https://github.com/jambun/pas_endpoints)
to make `endpoints`, `groups`, `nav` and `stub`, etc work.


    pas - a terminal client for ArchivesSpace

    pas             Start pas interactive shell
    pas -e cmd      Evaluate cmd and write output to stdout
    pas -h          This.

