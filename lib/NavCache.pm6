use Functions;

class CachedRef {
    has $.uri;
    has $.label;
    has $.property;
    has $.sort;

    submethod TWEAK {
        $!sort = $!label ~ $!uri;
    }
}

class Section {
    has $.label is rw;
    has CachedRef @.items is rw;
    has $.item_count is rw;
    has $.start_row is rw;
    has Bool $.sorted is rw;

    method is_active {
        $!start_row && @!items;
    }

    method add_item(CachedRef $ref) {
        @!items.push($ref);
    }

    method items {
        if $!sorted {
            @!items.sort({ .sort })
        } else {
            @!items;
        }
    }

    method start_index {
        0;
    }

    method end_index {
        +@!items - 1;
    }

    method size {
        +@!items;
    }

    method header {}

    method render {
        self.items.map({$_ ?? $_.label !! ''}).grep({$_}).join("\n");
    }
}

class PagedSection is Section {
    has $!page;
    has $!page_size;

    submethod TWEAK {
        $!page ||= 1;
        $!page_size ||= 10;
    }

    method size {
        if $!page !== 1 && $!page == (self.items / $!page_size).ceiling {
            self.items % $!page_size;
        } else {
            $!page_size;
        }
    }

    method page_size($size?) {
        if $size {
            $!page_size = ($size, +self.items).min;
        } else {
            $!page_size;
        }
    }

    method next_page {
        if $!page * $!page_size < self.items {
            $!page++;
        } else {
            False;
        }
    }

    method prev_page {
        if $!page > 1 {
            $!page--;
        } else {
            False;
        }
    }

    method start_index {
        (($!page - 1) * $!page_size);
    }

    method end_index {
        (($!page * $!page_size) - 1);
    }

    method header {
        if +self.items > $!page_size {
            (self.start_index() + 1) ~ ' to ' ~ (+self.items, (self.end_index() + 1)).min ~ ' of ' ~ (self.item_count || self.items.elems) ~ ' ' ~ self.label;
        } else {
            +self.items ~ ' ' ~ self.label;
        }
    }

    method render {
        my $out = ansi(self.header(), 'cyan');
        if self.size > 0 {
            $out ~= "\n" ~ self.items[self.start_index()..self.end_index()].map({$_ ?? $_.label !! ''}).grep({$!page > 1 || $_}).join("\n");
        }
        $out;
    }

    method last_page {
        $!page = (self.items / $!page_size).ceiling;
    }

    multi method page {
        $!page;
    }

    multi method page($i) {
        if $i >= 1 && ($i - 1) * $!page_size < self.items {
            $!page = $i;
        } else {
            False;
        }
    }
}


class CachedUri {
    has Str $.uri;
    has $.json is rw;
    has $.focus_section is rw;
    has $.focus_position is rw;
    has Str @.section_layout = <title parents children refs>;
    has Section %!sections;

    submethod TWEAK {
        %!sections = title    => Section.new(:label(<title>), :start_row(1)),
                     parents  => Section.new(:label(<parents>)),
                     children => PagedSection.new(:label(<children>)),
                     refs     => PagedSection.new(:label(<references>), :sorted);

        $!focus_section ||= <title>;
        $!focus_position ||= 1;
    }

    method section($section_name) {
        %!sections{$section_name};
    }

    method add_item($section_name, $uri, $label, $property?) {
        if (my $section = %!sections{$section_name}) {
            $section.add_item(CachedRef.new(:$uri, :$label, :$property));
        }
    }

    method focus_row {
        if (my $start = %!sections{$!focus_section}.start_row) {
            $start + $!focus_position - 1;
        } else {
            $!focus_section = @!section_layout[0];
            $!focus_position = 1;
            self.focus_row;
        }
    }

    method prev_active_section {
        my $sectix = @!section_layout.first($!focus_section, :k) - 1;
        $sectix-- until $sectix < 0 || %!sections{@!section_layout[$sectix]}.is_active;
        if $sectix < 0 {
            False;
        } else {
            @!section_layout[$sectix];
        }
    }

    method active_section {
        %!sections{$!focus_section};
    }

    method next_active_section {
        my $sectix = @!section_layout.first($!focus_section, :k) + 1;
        $sectix++ until $sectix >= @!section_layout || %!sections{@!section_layout[$sectix]}.is_active;
        if $sectix >=  @!section_layout {
            False;
        } else {
            @!section_layout[$sectix];
        }
    }

    method move_focus($direction) {
        $direction eq <prev> ?? self.prev_focus() !! self.next_focus();
    }

    method prev_focus {
        $!focus_position--;

        if $!focus_position < 1 {
            if (my $sect = self.prev_active_section) {
                $!focus_section = $sect;
                $!focus_position = %!sections{$sect}.size;
            } else {
                $!focus_position = 1;
                return False;
            }
        }
        ($!focus_section, $!focus_position);
    }

    method next_focus {
        $!focus_position++;

        if $!focus_position > %!sections{$!focus_section}.size {
            if (my $sect = self.next_active_section) {
                $!focus_section = $sect;
                $!focus_position = 1;
            } else {
                $!focus_position--;
                return False;
            }
            
        }
        ($!focus_section, $!focus_position);
    }

    method selected_ref {
        my $sect = self.active_section;
        $sect.items[$sect.start_index() + $!focus_position - 1];
    }
}

class NavCache {
    has CachedUri %.uris;

    method add_uri($uri, :$json) {
        %!uris{$uri} = CachedUri.new(:$uri, :$json);
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
