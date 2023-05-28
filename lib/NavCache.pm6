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
    has $.tree_page is rw;
    has $.tree_page_size is rw;
    has $.child_count is rw;
    has $.refs_page is rw;
    has $.focus_section is rw;
    has $.focus_position is rw;
    has CachedRef @.refs;
    has CachedRef @.children;

    submethod TWEAK {
        $!tree_page ||= 1;
        $!tree_page_size ||= 10;
        $!refs_page ||= 1;
        $!focus_section ||= <ref>;
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

    method page_start_index {
        (($!tree_page - 1) * $!tree_page_size);
    }

    method page_end_index {
        (($!tree_page * $!tree_page_size) - 1);
    }

    method tree_header {
        if $!child_count > $!tree_page_size {
            (self.page_start_index() + 1) ~ ' to ' ~ ($!child_count, (self.page_end_index() + 1)).min ~ ' of ' ~ $!child_count ~ ' children';
        } else {
            $!child_count ~ ' children';
        }
    }

    method tree_page {
        self.tree_header() ~ "\n" ~ self.children[self.page_start_index()..self.page_end_index()].map({$_ ?? $_.label !! ''}).join("\n");
    }

    method selected_uri {
        
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
