use Config;

class Pas::Logger {
    has Config $.config;

    method blurt($msg) {
	say $msg if $!config.attr<properties><loud>;
    }
}
