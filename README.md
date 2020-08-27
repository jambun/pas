# pas
An ArchivesSpace commandline client

Needs Perl6. Currently developing against:

      % perl6 --version
      This is Rakudo Star version 2018.10 built on MoarVM version 2018.10
      implementing Perl 6.c.

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

