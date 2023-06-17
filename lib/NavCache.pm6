use Functions;

class NavCache {...}

class CachedRef {
    has $.uri;
    has $.label;
    has $.property;
    has $.sort;

    submethod TWEAK {
        $!sort ||= $!label ~ $!uri;
    }
}

class Section {
    has $.label is rw;
    has CachedRef @.items is rw;
    has $.item_count is rw;
    has $.start_row is rw;
    has Bool $.sorted is rw;
    has Bool $.show_header is rw;
    has NavCache $.cache is rw;

    method is_active {
        return False if ($!label eq <parents> | <children>) && !$!cache.show_tree;

        $!start_row && @!items;
    }

    method add_item(CachedRef $ref, Int :$position) {
        if $position {
            @!items[$position] = $ref;
        } else {
            @!items.push($ref);
        }
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

    method header {
        self.size ~ ' ' ~ self.label;
    }

    method render {
        my @out;
        @out.push(ansi(self.header(), 'cyan')) if self.show_header;
        @out.push(|self.items.map({$_ ?? $_.label !! ''}).grep({$_}));
        @out.join("\n");
    }
}

class PagedSection is Section {
    has $!page;
    has $!page_size;

    submethod TWEAK {
        $!page ||= 1;
        $!page_size ||= 10;
        self.show_header = True;
    }

    # the number of items on the current page
    method size {
        if $!page !== 1 && $!page == (self.total_size / self.page_size).ceiling {
            self.total_size % self.page_size;
        } else {
            self.page_size;
        }
    }

    # the actual size if all items were loaded
    method total_size {
        self.item_count || self.items.elems;
    }

    method page_size($size?) {
        if $size {
            $!page_size = $size;
        } else {
            ($!page_size, self.total_size).min;
        }
    }

    method next_page {
        if $!page * self.page_size < self.total_size {
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
        (($!page - 1) * self.page_size);
    }

    method end_index {
        (($!page * self.page_size) - 1);
    }

    method header {
        if self.total_size > self.page_size {
            (self.start_index() + 1) ~ ' to ' ~ (self.total_size, (self.end_index() + 1)).min ~ ' of ' ~ self.total_size ~ ' ' ~ self.label;
        } else {
            self.total_size ~ ' ' ~ self.label;
        }
    }

    method render {
        my @out;
        @out.push(ansi(self.header(), 'cyan')) if self.show_header;
        if self.size > 0 {
            @out.push(|self.items[self.start_index()..self.end_index()].map({$_ ?? $_.label !! ''}).grep({$!page > 1 || $_}));
        }
        @out.join("\n");
    }

    method last_page {
        $!page = (self.total_size / self.page_size).ceiling;
    }

    multi method page {
        $!page;
    }

    multi method page($i) {
        if $i >= 1 && ($i - 1) * self.page_size < self.total_size {
            $!page = $i;
        } else {
            False;
        }
    }
}


class CachedUri {
    has Str $.uri;
    has $.json is rw;
    has NavCache $.cache is rw;
    has $.focus_section is rw;
    has $.focus_position is rw;
    has Str @.section_layout = <title parents children refs>;
    has Section %!sections;

    submethod TWEAK {
        %!sections = title    => Section.new(:label(<title>), :start_row(1), :cache($!cache)),
                     parents  => Section.new(:label(<parents>), :cache($!cache)),
                     children => PagedSection.new(:label(<children>), :cache($!cache)),
                     refs     => PagedSection.new(:label(<references>), :sorted, :cache($!cache));

        $!focus_section ||= <title>;
        $!focus_position ||= 1;
    }

    method section($section_name) {
        %!sections{$section_name};
    }

    method focussed_section {
        %!sections{$!focus_section};
    }

    method focus_position {
        ($!focus_position, self.focussed_section.size).min;
    }

    method add_item($section_name, $uri, $label, $property?, :$sort) {
        if (my $section = %!sections{$section_name}) {
            $section.add_item(CachedRef.new(:$uri, :$label, :$property, :$sort));
        }
    }

    method focus_row {
        if !(($!focus_section eq <parents> | <children>) && !$!cache.show_tree) && (my $start = self.focussed_section.start_row) {
            $start++ if self.focussed_section.show_header;
            $start + self.focus_position - 1;
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
        $!focus_position = self.focus_position - 1;

        if $!focus_position < 1 {
            if (my $sect = self.prev_active_section) {
                $!focus_section = $sect;
                $!focus_position = %!sections{$sect}.size;
            } else {
                $!focus_position = 1;
                return False;
            }
        }
        ($!focus_section, self.focus_position);
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
        ($!focus_section, self.focus_position);
    }

    method selected_ref {
        my $sect = self.focussed_section;
        $sect.items[$sect.start_index() + self.focus_position - 1];
    }
}

class NavCache {
    has CachedUri %.uris;
    has Bool $.show_tree is rw;

    method add_uri($uri, :$json) {
        %!uris{$uri} = CachedUri.new(:$uri, :$json, :cache(self));
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
