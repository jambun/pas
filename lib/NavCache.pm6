class CachedRef {
    has $.uri;
    has $.label;
    has $.sort;

    submethod TWEAK {
        $!sort = $!label ~ $!uri;
    }
}

class CachedUri {
    has Str $.uri;
    has $.json is rw;
    has $!tree_page;
    has $!tree_page_size;
    has $.child_count is rw;
    has $.refs_page is rw;
    has $!refs_page_size;
    has $.focus_section is rw;
    has $.focus_position is rw;
    has CachedRef @.refs;
    has CachedRef @.children;

    submethod TWEAK {
        $!tree_page ||= 1;
        $!tree_page_size ||= 10;
        $!refs_page ||= 1;
        $!refs_page_size ||= +@!refs;
        $!focus_section ||= <refs>;
        $!focus_position ||= 1;
    }

    method add_ref($uri, $label) {
        @!refs.push(CachedRef.new(:$uri, :$label));
    }

    method add_child($uri, $label) {
        @!children.push(CachedRef.new(:$uri, :$label));
    }

    method refs {
        @!refs.sort({ .sort })
    }

    method children {
        @!children;
    }

    method tree_page_size($size?) {
        if $size {
            $!tree_page_size = ($size, +@!children).min;
        } else {
            $!tree_page_size;
        }
    }

    method refs_page_size($size?) {
        if $size {
            $!refs_page_size = ($size, +@!refs).min;
        } else {
            $!refs_page_size;
        }
    }

    method next_tree_page {
        if $!tree_page * $!tree_page_size < @!children {
            $!tree_page++;
        } else {
            False;
        }
    }

    method prev_tree_page {
        if $!tree_page > 1 {
            $!tree_page--;
        } else {
            False;
        }
    }

    method refs_page_start_index {
        (($!refs_page - 1) * $!refs_page_size);
    }

    method refs_page_end_index {
        (($!refs_page * $!refs_page_size) - 1);
    }

    method refs_header {
        if +@!refs > $!refs_page_size {
            (self.refs_page_start_index() + 1) ~ ' to ' ~ (+@!refs, (self.refs_page_end_index() + 1)).min ~ ' of ' ~ @!refs.elems ~ ' links';
        } else {
            +@!refs ~ ' links';
        }
    }

    method tree_page_start_index {
        (($!tree_page - 1) * $!tree_page_size);
    }

    method tree_page_end_index {
        (($!tree_page * $!tree_page_size) - 1);
    }

    method tree_header {
        if $!child_count > $!tree_page_size {
            (self.tree_page_start_index() + 1) ~ ' to ' ~ ($!child_count, (self.tree_page_end_index() + 1)).min ~ ' of ' ~ $!child_count ~ ' children';
        } else {
            $!child_count ~ ' children';
        }
    }

    method last_tree_page {
        $!tree_page = (@!children / $!tree_page_size).ceiling;
    }

    multi method tree_page {
        $!tree_page;
    }

    multi method tree_page($i) {
        if $i >= 1 && ($i - 1) * $!tree_page_size < @!children {
            $!tree_page = $i;
        } else {
            False;
        }
    }

    method render_refs_page {
        self.refs_header() ~ "\n" ~ self.refs[self.refs_page_start_index()..self.refs_page_end_index()].map({$_ ?? $_.label !! ''}).grep({$!refs_page > 1 || $_}).join("\n");
    }

    method render_tree_page {
        self.tree_header() ~ "\n" ~ self.children[self.tree_page_start_index()..self.tree_page_end_index()].map({$_ ?? $_.label !! ''}).grep({$!tree_page > 1 || $_}).join("\n");
    }

    method move_focus($direction) {
        $direction eq <prev> ?? self.prev_focus() !! self.next_focus();
    }

    method prev_focus {
        $!focus_position--;

        if $!focus_position < 1 {
            if $!focus_section eq <refs> && self.children() {
                $!focus_section = <tree>;
                $!focus_position = $!tree_page_size;
            } else {
                $!focus_position = 1;
                return False;
            }
        }
        ($!focus_section, $!focus_position);
    }

    method next_focus {
        $!focus_position++;
        if $!focus_section eq <tree> {
            if $!focus_position > $!tree_page_size {
                $!focus_section = <refs>;
                $!focus_position = 1;
            }
        } else {
            if $!focus_position > $!refs_page_size {
                $!focus_position = $!refs_page_size;
                return False;
            }
        }
        ($!focus_section, $!focus_position);
    }

    method selected_ref {
        if $!focus_section eq <tree> {
            self.children[self.tree_page_start_index() + $!focus_position - 1];
        } elsif $!focus_section eq <refs> {
            self.refs[self.refs_page_start_index() + $!focus_position - 1];
        } else {
            False;
        }
    }

    method ref_at(:$section, :$position) {
        if $section eq <tree> {
            
        } elsif $section eq <refs> {

        }
    }
}

class NavCache {
    has CachedUri %.uris;

    method add_uri($uri, :$json, :$tree_page, :$ref_page, :$focus_section, :$focus_position) {
        %!uris{$uri} = CachedUri.new(:$uri, :$json, :$tree_page, :$ref_page, :$focus_section, :$focus_position);
    }

    method is_cached($uri) {
        %!uris{$uri}:exists;
    }

    method uri($uri) {
        %!uris{$uri};
    }

    method remove($uri) {
        %!uris{$uri}:delete;
    }

    method clear {
        %!uris = Empty;
    }
}
