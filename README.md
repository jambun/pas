# pas

An ArchivesSpace commandline client

Needs Raku (Perl6). Currently developing against:

    % perl6 --version
    Welcome to Rakudo™ v2022.06.
    Implementing the Raku® Programming Language v6.d.
    Built on MoarVM version 2022.06.

On an M1 Mac.

    % zef install JSON::Tiny
    % zef install Terminal::ANSIColor
    % zef install HTTP::UserAgent
    % zef install URI::Encode
    % zef install XML
    % zef install Digest::MD5
    % zef install Crypt::Random

And an ArchivesSpace [plugin](https://github.com/jambun/pas_endpoints)
to make `endpoints`, `groups` and `stub`, etc work.


    pas - a terminal client for ArchivesSpace

    pas             Start pas interactive shell
    pas -e cmd      Evaluate cmd and write output to stdout
    pas -h          This.

