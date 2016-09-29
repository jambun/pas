
class Pas::Store {
    has Str $.dir;

    method path($file) {
	$!dir ~ '/' ~ $file;
    }


    method load($file) {
	slurp self.path($file);
    }
    

    method save($file, $data) {
	mkdir($!dir);
	spurt $!dir ~ '/' ~ $file, $data;
    }

}
