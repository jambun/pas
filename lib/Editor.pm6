use Functions;

use Terminal::LineEditor;
use Terminal::LineEditor::RawTerminalInput;
use JSON::Tiny;

class FormField {
    has $.prop;
    has FormField $.parent;
    has Int $.depth = 0;
    has $.schema;
    has $.value is rw;
    has $.error is rw;
    has $.original-value;
    has Bool $.open-for-update is rw = False;

    has @.subrecords; # a FormField array for each sub-record in this field
    has $.subrecord-ix is rw; # the array index of the currently selected subrecord

    # probably not required in the new regime
    has @.original-subrecord-map; # keeps track of original subrecord indexes for comparing with original-value

    has Int $.value-ix is rw; # the array index of the current value in the list of possible values - enum, bool
    has Str $.label is rw; # added to value when rendered - display string or enum translation

    submethod TWEAK {
        # storing it as json - annoying but deep structures are passed by ref
        # so get mutated when they change in $!value - tried deepmap, no go
        $!original-value = to-json $!original-value || $!value;

        self.load-subrecords;

        self.set-original-subrecord-map;
        self.set-label;
    }

    my $.prop-width;

    method original-value {
        from-json $!original-value;
    }

    method set-value($value) {
        $!value = $value;
        self.set-label;
        $!error = Nil;
        if $!parent {
            $!parent.set-child-value(self);
        }
    }

    method set-child-value($child, $ix = $!subrecord-ix) {
        if $!value[$ix] !~~ Iterable {
            $!value[$ix] = $child.value;
        } else {
            $!value[$ix]{$child.prop} = $child.value;
        }
        self.set-label;
        $!error = Nil;
        if $!parent {
            $!parent.set-child-value(self);
        }
    }

    method set-label {
        if $!schema<dynamic_enum> && $!value {
            $!label = enum-by-name($!schema<dynamic_enum>)<value_translations>{$!value};
        } elsif $!value ~~ Hash && $!value<_resolved> {
            $!label = label-for-json($!value<_resolved>);
        }
    }

    method set-labels-for(%ref-map) {
        if ($!prop eq <ref> && %ref-map{$!value}) {
            $!label = label-for-json(%ref-map{$!value});
        }

        for @!subrecords -> $sr { for |$sr { .set-labels-for(%ref-map); } }
    }

    method load-subrecords {
        unless $!schema<type> eq 'array' | 'object' {
            return;
        }

        @!subrecords = Empty;

        my @subrecs = $!schema<type> eq 'object'
                          ?? [$!value]
                          !! |$!value;

        for @subrecs -> $rec {
            my @subrecord;
            my @prop-names;
            my %props;

            if $rec<jsonmodel_type> {
                my $item-schema = schemas(:name($rec<jsonmodel_type>));
                @prop-names = |$item-schema<property_list>;
                %props = $item-schema<properties>;
            } else {
                %props = $!schema<type> eq 'object'
                             ?? $!schema<properties>
                             !! ($!schema<items><properties> || {item => $!schema<items>});
                @prop-names = %props.keys;
            }

            for @prop-names -> $prop {
                next if $prop ~~ /^ '_' /;
                my $schema-prop = %props{$prop};
                next if $schema-prop<readonly>;
                next if EDIT_SKIP_PROPS.grep($prop);

                my $label = ($prop eq <ref> && $rec<_resolved>) ?? label-for-json($rec<_resolved>) !! '';
                my $val = $prop eq <item> ?? $rec !! $rec{$prop};

                @subrecord.push(FormField.new(:$prop,
                                              :parent(self),
                                              :depth(self.depth + 1),
                                              :schema($schema-prop),
                                              :$label,
                                              :value($val)));
            }

            @!subrecords.push(@subrecord);
        }
    }

    method subrecord-open {
        $!subrecord-ix.defined;
    }

    method close-subrecord {
        $!subrecord-ix = Nil;
    }

    method current-subrecord {
        return Empty unless @!subrecords && $!subrecord-ix.defined;

        @!subrecords[$!subrecord-ix];
    }

    method next-subrecord {
        return Empty unless @!subrecords;

        if $!subrecord-ix.defined {
            $!subrecord-ix++;
        } else {
            $!subrecord-ix = 0;
        }

        $!subrecord-ix = $!subrecord-ix % @!subrecords;

        @!subrecords[$!subrecord-ix];
    }

    method set-original-subrecord-map {
        @!original-subrecord-map = ^$!value.elems;
    }

    # not used - delete?
    method next-value {
        if $!value-ix.defined {
            $!value-ix = ($!value-ix + 1) % $!value.elems;
            if $!value-ix == 0 { $!value-ix = Nil; }
        } else {
            $!value-ix = 0;
        }
    }

    method delete-subrecord($ix) {
        $!value.splice($ix, 1);
        @!original-subrecord-map.splice($ix, 1);
    }

    method original-value-ix($ix) {
        @!original-subrecord-map[$ix];
    }

    method updated {
        my $ov = self.original-value;
        if $!value ~~ Hash {
            $!value.grep({ .key ne <_resolved> }).Hash !eqv $ov;
        } elsif $!value ~~ Iterable && $!value.head ~~ Hash {
            $!value.map({ %(.grep({ .key ne <_resolved> }))}).Array !eqv $ov;
        } else {
            $!value !eqv $ov;
        }
    }

    method render(:$selected) {
        my $value-style = '';
        if $!error {
            $value-style = 'red';
        } elsif $!open-for-update {
            $value-style = 'green';
        } elsif self.updated {
            $value-style = 'cyan';
        }

        my $val = $!value.clone;

        if !$val.defined || ($val ~~ Str && $val eq '') {
            $val = ansi('--', $value-style);
        } elsif $val ~~ Hash {
            if $val.keys.grep({ $_ !~~ /^ '_'/ }).elems > 1 {
                $val = ansi($!prop, "bold $value-style") ~ " {$val.elems} properties";
            } else {
                if $val<ref> && self.label {
                    $val = ansi($val<ref> ~ ' | ' ~ self.label, "bold $value-style");
                } else {
                    my $k = $val.keys.first({ $_ !~~ /^ '_'/ });
                    $val = ansi($k ~ ': ' ~ $val{$k}, "bold $value-style");
                }
            }
        } elsif $val ~~ Iterable {
            if $!value-ix.defined {
                my $item = $val[$!value-ix];
                if $item<ref> {
                    if $item<_resolved> {
                        my $label = label-for-json($item<_resolved>);
                        $val = ansi($item<ref> ~ ' | ' ~ $label, "bold $value-style");
                    } else {
                        $val = ansi($item<ref>, "bold $value-style");
                    }
                } else {
                    $val = ansi($item.gist, "bold $value-style");
                }
            } elsif self.subrecord-open {
                $val = ansi("{$!subrecord-ix + 1} of {$val.elems}", "bold $value-style") ~ ' ' ~ $!prop;
            } else {
                $val = ansi($val.elems.Str, "bold $value-style") ~ ' ' ~ $!prop;
            }
        } else {
            $val.=trans("\n" => ' ');
            my $max_val_length = term_cols() - self.prop-width - 20;

            if $!label {
                $val ~= " | $!label";
            }

            if $val.chars > $max_val_length {
                $val = $val.substr(0,$max_val_length) ~ ' ...';
            }
            $val = ansi($val, "bold $value-style");
        }

        if $!error {
            $val ~= '  ' ~ ansi($!error, 'red');
        }

        my $cursor = $selected ?? ansi('>>', 'bold green') !! '::';

        sprintf("%{self.prop-width}s{'  ' x $!depth} $cursor %s", $!prop, $val);
    }
}

class Editor {
    has %.json; # the parsed json of the record
    has $.schema; # the JSONModel schema for the record's type
    has FormField @.fields; # a FormField for each editable property in the schema
    has $.selected-field-ix = 0; # the array index of the currently selected field
    has $.cursor-offset;
    has $.top-field-ix = 0;

    has @.record-stack; # previously loaded records stacked so they can be returned to

    has $.number-of-display-lines = term_lines() - 6;
    has $.first-display-line = 3;
    has @.skip_props = <uri created_by last_modified_by jsonmodel_type user_mtime system_mtime create_time lock_version>;

    my @default-help =
        'Q' => 'Quit',
        'S' => 'Save',
        "\c[UPWARDS ARROW] \c[DOWNWARDS ARROW]" => 'Cursor',
        "\c[LEFTWARDS ARROW] \c[RIGHTWARDS ARROW]" => 'Scroll',
        '1 2 +' => 'Page',
        'M' => 'Model',
        'J' => 'JSON',
        'V' => 'Value',
        'SPACE' => 'Edit',
        'TAB' => 'Revert',
        'D' => 'Delete';

    my @array-help =
        'A' => 'Add';

    my @add-value-help =
        'Query' => 'Type search query',
        'SPACE' => 'Next result',
        'RETURN' => 'Add selected result',
        'TAB' => 'Exit';

    my @subrecord-help =
         'A' => 'Add subrecord',
         'C' => 'Close subrecords';

    submethod TWEAK {
        self.init;
    }

    method init(%json?, :$previous) {
        if %json {
            @!record-stack.push(%!json.clone);
            %!json = %json;
        } elsif $previous {
            if @!record-stack {
                %!json = @!record-stack.pop;
            } else {
                self.message('No previous record to load');
                return;
            }
        }

        $!schema = schemas(:name(%!json<jsonmodel_type>));

        return unless $!schema;

        my @props = |$!schema<property_list>;
        my $longest = @props>>.chars.max;
        my $max_val_length = term_cols() - $longest - 20;
        $!cursor-offset = $longest + 3;
        FormField.prop-width = $longest;

        $!selected-field-ix = 0;
        $!top-field-ix = 0;

        self.load-fields;

        True;
    }

    method load-record($uri) {
        my $resp = from-json client.get($uri);
        if $resp<error> {
            self.message($resp<error>);
        } else {
            self.init($resp);
            self.draw-page;
        }
    }

    method load-previous-record {
        self.init(:previous) && self.draw-page;
    }

    method max-top-field-ix {
        [0, @!fields.elems - $!number-of-display-lines].max;
    }

    method last-display-line {
        $!number-of-display-lines + $!first-display-line;
    }

    method load-fields {
        @!fields = Empty;

        for |$!schema<property_list> -> $prop {
            my $schema_prop = $!schema<properties>{$prop};
            next if $schema_prop<readonly>;
            next if @!skip_props.grep($prop);

            @!fields.push(FormField.new(:$prop, :schema($schema_prop), :value(%!json{$prop})));
        }
    }

    method load-subrecord-fields {
        unless self.field.schema<type> eq 'array' | 'object' {
            self.message(self.field.prop ~ ' does not contain subrecords');
            return;
        }

        self.draw-next-subrecord;
        self.draw-help(@subrecord-help, :add);
    }

    method field-for-prop($prop, $ix?, $subprop?) {
        if $ix {
            if $subprop {
                self.field.subrecords[$ix].first: *.prop eq $subprop;
            } else {
                self.message("Yikes - called field-for-prop with an ix but no subprop");
            }
        } else {
            @!fields.first: *.prop eq $prop;
        }
    }

    method field-with-open-subrecord {
        @!fields.first(:end, *.subrecord-open);
    }

    method ix-of-field-with-open-subrecord {
        @!fields.first(:end, *.subrecord-open) :k;
    }

    method ix-of-first-field-with-open-subrecord {
        @!fields.first(*.subrecord-open) :k;
    }

    method remove-subrecord-fields {
        @!fields.=grep({ !(.parent && .parent === self.field) });
    }

    method draw-remove-subrecord {
        if (my $open-ix = self.ix-of-field-with-open-subrecord).defined {
            $!selected-field-ix = $open-ix;
        }

        self.field.close-subrecord;

        self.remove-subrecord-fields;

        self.draw-form;
        self.draw-help;
    }

    method draw-next-subrecord {
        return unless self.field.subrecords;

        self.remove-subrecord-fields;

        @!fields.splice($!selected-field-ix + 1, 0, self.field.next-subrecord);

        self.draw-form;
    }

    method revert-value {
        self.set-value(self.field.original-value);
        self.field.set-original-subrecord-map;
    }

    method set-value($value) {
        self.field.set-value($value);
    }

    method message($s) {
        print-at(term_lines() - 1, 3, ansi($s.gist, 'yellow'), :fill);
    }

    method field {
        @!fields[$!selected-field-ix];
    }

    method move-cursor(Int $d) {
        my $old-ix = $!selected-field-ix;
        my $new-ix = $!selected-field-ix + $d;
        my $open-subrecord-ix = self.ix-of-field-with-open-subrecord;

        if $new-ix < 0 || $new-ix < $!top-field-ix
                       || $new-ix >= @!fields.elems
                       || $new-ix > $!number-of-display-lines + $!top-field-ix
                       || ($open-subrecord-ix.defined && $new-ix < $open-subrecord-ix)
                       || ($open-subrecord-ix.defined && $new-ix > $open-subrecord-ix + self.field-with-open-subrecord.current-subrecord) {
            print BEL;
        } else {
            self.field.open-for-update = False;
            self.field.value-ix = Nil;

            $!selected-field-ix = $new-ix;
            self.draw-field($old-ix);
            self.draw-field;
            self.draw-help;
        }
    }

    method draw-ref-search {
        my %search;
        my $ix = 0;
        my $q = '';
        my $type = self.field.schema<type>;
        if $type ~~ Array {
            for |$type -> $t {
                $t<type> ~~ s/^ 'JSONModel(:' (\w+) ') uri' $/$0/;
            }
            $type = $type.map(*.<type>).Array;
        } else {
            $type ~~ s/^ 'JSONModel(:' (\w+) ') uri' $/$0/;
        }

        my %c = col => $!cursor-offset + self.field.depth * 2 + 3, line => self.field-display-line;

        print-at(%c<line>, %c<col>, ansi('Search: ', 'green') ~ ansi('_', 'bold'), :fill);

        while (my $ak = get-key-in) {
            given $ak {
                when "\t" {
                    self.message("Exited linker");
                    last;
                }
                when /\n/ {
                    self.set-value(%search<results>[$ix]<uri>);
                    self.field.label = %search<results>[$ix]<title>;

                    self.draw-field;
                    self.message('Linked ' ~ self.field.value);
                    last;
                }
                when ' ' {
                    if %search<results> {
                        $ix = ($ix + 1) % +%search<results>;
                        my $msg = %search<results>[$ix]<uri>;
                        if %search<results>[$ix]<title> {
                            $msg ~= ' | ' ~ %search<results>[$ix]<title>;
                        }
                        self.message($msg);
                    }
                }
                default {
                    if $ak ~~ /\w/ {
                        $q ~= $ak;
                    } elsif $ak.ord == 127 {
                        $q.=substr(0, *-1) if $q;
                    }
                    if $q {
                        %search = self.search-type($type, $q);
                        print-at(%c<line>, %c<col> + 8, ansi($q ~ '_', 'bold') ~ '  ' ~ %search<total_hits> ~ ' hits', :fill);
                    } else {
                        print-at(%c<line>, %c<col> + 8, ansi($q ~ '_', 'bold'), :fill);
                    }
                }
            }
        }
    }

    method field-display-line($ix = $!selected-field-ix) {
        $!first-display-line + $ix - $!top-field-ix;
    }

    method ix-for-field(FormField $field --> Int) {
        @!fields.first(* === $field) :k;
    }

    method draw-field($ix = $!selected-field-ix) {
        my $line = self.field-display-line($ix);

        if $line < $!first-display-line || $line > self.last-display-line {
            return;
        }

        if (my $field = @!fields[$ix]) {
            print-at($line, 2, $field.render(:selected($ix == $!selected-field-ix)), :fill);

            if $field.parent {
                self.draw-field(self.ix-for-field($field.parent));
            }
        } else {
            print-at($line, 2, ' ', :fill);
        }
    }

    method draw-form {
        for 0 .. $!number-of-display-lines -> $i {
            my $ix = $i + $!top-field-ix;
            self.draw-field($ix);
        }

        my $leading-count = $!top-field-ix;

        if $leading-count <= 0 {
            print-at($!first-display-line - 1,
                     $!cursor-offset,
                     ' ', :clear);
        } elsif $leading-count > 0 {
            print-at($!first-display-line - 1,
                     $!cursor-offset,
                     ansi('.', 'green') x $leading-count, :clear);
        }

        my $trailing-count = @!fields.elems - $!number-of-display-lines - $!top-field-ix - 1;

        if $trailing-count <= 0 {
            print-at($!number-of-display-lines + $!first-display-line + 1,
                     $!cursor-offset,
                     ' ', :clear);
        } elsif $trailing-count > 0 {
            print-at($!number-of-display-lines + $!first-display-line + 1,
                     $!cursor-offset,
                     ansi('.', 'green') x $trailing-count, :clear);
        }
    }

    method draw-page {
        clear-screen();
        self.draw-header;
        self.draw-footer;
        self.draw-form;
    }

    method draw-header {
        my $label = (%!json<uri>, label-for-json(%!json)).grep(*.so).join(' | ');
        $label = ('.' x @!record-stack) ~ ' ' ~ $label;
        print-at(1, 2, ansi($label, 'bold'), :clear);
    }

    method draw-footer {
        self.draw-help;
    }

    method draw-help(@items? is copy, :$add) {
        if $add && @items {
            @items = |@default-help, |@items;
        } else {
            @items ||= @default-help;
        }
        my $help-txt;
        for @items -> $i {
            $help-txt ~= ' | ' if $help-txt;
            if $i.key eq $i.value.substr(0,1) {
                $help-txt ~= ansi($i.key, 'bold green') ~ $i.value.substr(1);
            } else {
                $help-txt ~= ansi($i.key, 'bold green') ~ ' ' ~ $i.value;
            }
        }
        print-at(term_lines(), 3, $help-txt, :fill);
    }

    method edit-screen(:$embedded) {
        ENTER {
            run <tput civis> unless $embedded;
        }
        LEAVE {
            cursor(0, term_lines());
            run <tput cvvis> unless $embedded;
        }

        self.draw-page;

        my $k = '';

        while $k ne 'q' {

	          $k = get-key-in;

	          given $k {
                when 's' {
                    for @!fields.grep(*.updated) -> $field {
                        %!json{$field.prop} = $field.value;
                    }

                    my %resp = from-json client.post(%!json<uri>, Empty, to-json %!json);

                    if %resp<error> {
                        my @err-msg;
                        for @!fields -> $f { $f.error = Nil }
                        for %resp<error>.kv -> $k, $v {
                            @err-msg.push($k ~ ' :: ' ~ $v.join(','));

                            for @!fields.grep(*.updated) -> $field {
                                %!json{$field.prop} = $field.original-value;
                            }

                            if $k eq <identifier> && self.field-for-prop(<id_0>) {
                                for <id_0 id_1 id_2 id_3> -> $id {
                                    my $field = self.field-for-prop($id);
                                    if $field.value {
                                        last;
                                    } else {
                                        $field.error = $v.join(', ');
                                    }
                                }
                            } else {
                                self.field-for-prop(|$k.split('/')).error = $v.join(', ');
                            }
                            self.draw-form;
                        }

                        self.message('Error - record not saved: ' ~ @err-msg.join(' | '));
                    } else {
                        self.message(%resp<status>);

                        if (my $open-subrecord-ix = self.ix-of-first-field-with-open-subrecord).defined {
                            $!selected-field-ix = $open-subrecord-ix;
                        }

                        # reload json after the update
                        %resp = from-json client.get(%!json<uri>);

                        if %resp<error> {
                            my $msg = '';
                            for %resp<error>.kv -> $k, $v {
                                $msg ~= $k ~ ': ' ~ $v.join(',') ~ '  ';
                            }

                            self.message($msg);
                        } else {
                            %!json = %resp;
                            self.load-fields;
                        }

                        self.draw-form;
                    }
               }
                when "\t" {
                    self.revert-value;
                    self.draw-field;
                }
                when 'd' {
                    if self.field.value ~~ Iterable {
                        # if $!subrecord-ix.defined {
                        #     self.field.delete-subrecord($!subrecord-ix);
                        #     self.set-value(self.field.value);
                        #     self.message("Item deleted from {self.field.prop}");
                        # } else {
                        #     self.set-value([]);
                        #     self.message("All {self.field.prop} deleted");
                        # }
                        # self.load-subrecord-fields;
                        self.message('Sorry, not yet reimplemented after the refactor');
                    } else {
                        self.set-value('');
                    }
                    self.draw-field;
                }
                when 'a' {

                }
                when ' ' {
                    my $prop = self.field.schema;

                    if self.field.open-for-update {
                        if $prop<type> eq 'boolean' {
                            self.set-value(!self.field.value);
                            self.draw-field;
                        } elsif $prop<enum> {
                            my $next-ix = $prop<enum>.first(self.field.value, :k) + 1;
                            $next-ix %= $prop<enum>.elems;
                            self.set-value($prop<enum>[$next-ix]);
                            self.draw-field;
                        } elsif $prop<dynamic_enum> {
                            my $enum = enum-by-name($prop<dynamic_enum>);
                            my @values = |$enum<values>;
                            my $next-ix = @values.first(self.field.value, :k) + 1;
                            $next-ix %= @values.elems;
                            self.set-value(@values[$next-ix]);
                            self.field.set-label;
                            self.draw-field;
                        } elsif $prop<type> eq 'string' {
                            my $val = self.field.value // '';
                            if $val.chars > term_cols() - $!cursor-offset - 20 || $val ~~ /\n/ {
                                save_tmp(self.field.value);
                                if edit(tmp_file) {
                                    self.set-value(slurp(tmp_file).chomp);
                                    self.message('Edits applied');
                                } else {
                                    self.message('No edits');
                                }
                                run <tput civis>;
                            } else {
                                my $coo = self.field.depth * 2 + 2;;
                                cursor($!cursor-offset + $coo, $!first-display-line + $!selected-field-ix - $!top-field-ix);
                                run <tput cvvis>;
                                my $cli = Terminal::LineEditor::CLIInput.new;

                                # these don't work :( i see the value appear but gets blatted immediately
                                # $cli.replace-input-field(:50display-width, :0field-start, :content($field.value));
                                # $cli.do-edit('insert-string', $field.value);

                                # so use history instead - sigh
                                $cli.add-history(self.field.value);

                                self.set-value($cli.prompt);
                                run <tput civis>;
                                self.draw-field;
                            }
                        } elsif $prop<type> eq 'array' {
                            self.draw-next-subrecord;
                        }
                    } else {
                        self.field.open-for-update = True;

                        if self.field.prop eq <ref> {
                            self.draw-ref-search;
                        } elsif $prop<type> eq <array> | <object> {
                            if !self.field.label {
                                if $prop<subtype> ~~ <ref> || ($prop<items> && $prop<items><subtype> ~~ <ref>) {
                                    my $resp = from-json client.get(%!json<uri>, ('resolve[]=' ~ self.field.prop,));
                                    if $resp<error> {
                                        self.message($resp<error>);
                                    } else {
                                        my %ref-map;
                                        if $resp{self.field.prop} ~~ Associative {
                                            %ref-map = $resp{self.field.prop}<ref> => $resp{self.field.prop}<_resolved>;
                                            self.field.label = label-for-json(%ref-map.values.head);
                                        } else {
                                            %ref-map = $resp{self.field.prop}.map({ .<ref> => .<_resolved> });
                                            self.field.label = 'Resolved';
                                        }
                                        for @!fields { .set-labels-for(%ref-map); }
                                    }
                                }
                            }
                            self.draw-next-subrecord;
                            self.draw-help(@array-help, :add);
                        }

                        self.draw-field;
                    }
                }
                when 'c' {
                    self.draw-remove-subrecord;
                }
                when 'm' {
                    page(pretty to-json self.field.schema);
                }
                when 'M' {
                    page(pretty to-json self.schema);
                }
                when 'v' {
                    page(pretty to-json self.field.value);
                }
                when 'V' {
                    page(pretty to-json self.field.original-value);
                }
                when 'j' {
                    page(pretty to-json %!json{self.field.prop});
                }
                when 'J' {
                    page(pretty to-json %!json);
                }
                when 'u' {
                    page(pretty to-json self.field.subrecords.raku);
                }
                when 'g' {
                    if self.field.prop eq <ref> {
                        self.load-record(self.field.value);
                    } else {
                        print BEL;
                    }
                }
                when 'b' {
                    self.load-previous-record;
                }
                when /\d/ {
                    my $ix = $!number-of-display-lines * ($k - 1);
                    if $ix > +@!fields || self.field-with-open-subrecord {
                        print BEL;
                    } else {
                        $!top-field-ix = $ix;
                        $!selected-field-ix = $ix;
                        self.draw-form;
                    }
                }
		            when UP_ARROW {
                    self.move-cursor(-1);

                }
		            when DOWN_ARROW {
                    self.move-cursor(1);

		            }
		            when RIGHT_ARROW {
                    if $!top-field-ix + 1 >= self.max-top-field-ix {
                        print BEL;
                    } elsif $!top-field-ix + 1 > $!selected-field-ix {
                        print BEL;
                    } else {
                        $!top-field-ix++;
                        self.draw-form();
                    }
		            }
		            when LEFT_ARROW {
                    if $!top-field-ix < 1 {
                        print BEL;
                    } elsif $!top-field-ix + 1 < $!selected-field-ix - $!number-of-display-lines + 2 {
                        print BEL;
                    } else {
                        $!top-field-ix--;
                        self.draw-form();
                    }
		            }
	          }

        }

        print-at(term_lines(), 1, ' ', :fill);

        "Closed form for {%!json<uri>}";
    }

    method search-type($type, $q) {
        my @args = 'page=1', "q=$q";

        for |$type -> $t {
            @args.push("type[]=$t");
        }

        my %resp = from-json client.get(SEARCH_URI, @args);

        if %resp<error> {
            self.message("Error searching for $type with '$q': " ~ %resp<error>);
        }

        %resp;
    }

   method is-subrecord($type-def --> Bool) {
       if $type-def ~~ Iterable {
           so all $type-def.map({ $_<type> ~~ /^ 'JSONModel(:' \w+ ') object' $/ });
       } else {
           ($type-def ~~ /^ 'JSONModel(:' \w+ ') object' $/).so;
       }
    }

   method subrecord-type($type-def) {
       $type-def ~~ /^ 'JSONModel(:' (\w+) ') object' $/;
       $0.Str;
   }
}
