use Config;

use Terminal::ANSIColor;

class Pas::Logger {
    has Config $.config;

    method blurt($msg) {
	say colored($msg.Str, 'magenta') if $!config.attr<properties><loud>;
    }
}
