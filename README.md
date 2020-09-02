# pas
An ArchivesSpace commandline client

Needs Perl6. Currently developing against:

    % perl6 --version
    This is Rakudo version 2017.04.3 built on MoarVM version 2017.04-53-g66c6dda
    implementing Perl 6.c.

Newer versions all have problems - can't parse URIs properly, threading lockups,
can't compile HTTP::UserAgent. It's a bit ridiculous really. Losing faith.

With URI::Encode, XML and Crypt::Random:

      % zef install URI::Encode
      % zef install XML
      % zef install Crypt::Random

And an ArchivesSpace [plugin](https://github.com/jambun/pas_endpoints)
to make `endpoints`, `groups` and `stub` work.


    pas - a terminal client for ArchivesSpace

    pas             Start pas interactive shell
    pas -e cmd      Evaluate cmd and write output to stdout
    pas -h          This.

