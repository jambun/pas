use Functions;

use JSON::Tiny;

class Subrecord {...}
class CommandMode {...}
class CommandKey {...}

class FormField {
    has $.prop;
    has FormField $.parent;
    has Int $.depth = 0;
    has $.schema;
    has $.value is rw;
    has $.error is rw;
    has $.original-value;
    has Bool $.open-for-update is rw = False;

    has Subrecord @.subrecords; # a FormField array for each sub-record in this field
    has Subrecord @.original-subrecords; # a copy of @!subrecords at build time to support revert
    has $.subrecord-ix is rw; # the array index of the currently selected subrecord

    has Int $.value-ix is rw; # the array index of the current value in the list of possible values - enum, bool
    has Str $.label is rw; # added to value when rendered - display string or enum translation

    submethod TWEAK {
        # storing it as json - annoying but deep structures are passed by ref
        # so get mutated when they change in $!value - tried deepmap, no go
        $!original-value = to-json($!original-value || $!value);

        self.load-subrecords;

        self.set-label;
    }

    my $.prop-width;

    method clone {
        FormField.new(:$!prop,
                      :$!parent,
                      :$!depth,
                      :$!schema,
                      :$!label,
                      :value(self.original-value));
    }

    method revert-subrecords {
        @!subrecords = @!original-subrecords.map(*.clone);
    }

    method original-value {
        from-json $!original-value;
    }

    method set-value($value) {
        $!value = from-json to-json $value;
        self.set-label;
        $!error = Nil;
        if $!parent {
            $!parent.set-child-value(self);
        }
    }

    method set-child-value($child, $ix = $!subrecord-ix) {
        if is-subrecord($!schema) {
            $!value{$child.prop} = $child.value;
        } elsif $!value[$ix] ~~ Associative {
            $!value[$ix]{$child.prop} = $child.value;
        } else {
            $!value[$ix] = $child.value;
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
        return unless %ref-map;

        if ($!prop eq <ref> && $!value ~~ Str:D && %ref-map{$!value}) {
            $!label = label-for-json(%ref-map{$!value});
        }

        for @!subrecords -> $sr { for $sr.fields { .set-labels-for(%ref-map); } }
    }

    method load-subrecords {
        unless $!schema<type> eq 'array' | 'object' || is-subrecord($!schema<type>) {
            return;
        }

        @!subrecords = Empty;

        my @subrecs = $!schema<type> eq 'array'
                          ?? |$!value
                          !! [$!value];

        for @subrecs -> $rec {
            my @subrecord;
            my @prop-names;
            my %props;

            if $rec<jsonmodel_type> {
                my $item-schema = schemas(:name($rec<jsonmodel_type>));
                @prop-names = |$item-schema<property_list>;
                %props = $item-schema<properties>;
            } elsif is-subrecord($!schema<type>) {
                my $item-schema = schemas(:name(subrecord-type($!schema<type>)));
                @prop-names = |$item-schema<property_list>;
                %props = $item-schema<properties>;
            } else {
                %props = $!schema<type> eq 'object'
                             ?? $!schema<properties>
                             !! ($!schema<items><properties> || {item => $!schema<items>});
                @prop-names = %props.keys;
            }

            @!subrecords.push(self.build-subrecord-with(%props, @prop-names, $rec));
        }

        @!original-subrecords = @!subrecords.map(*.clone);
    }

    method build-subrecord-with(%props, @prop-names is copy, $rec = {}) {
        my @subrecord;

        @prop-names ||= %props.keys;

        for @prop-names -> $prop {
            next if $prop ~~ /^ '_' /;
            my $schema-prop = %props{$prop};
            next if $schema-prop<readonly>;
            next if EDIT_SKIP_PROPS.grep($prop);

            my $label = ($prop eq <ref> && $rec<_resolved>) ?? label-for-json($rec<_resolved>) !! '';
            my $val = $prop eq <item> ?? $rec !! $rec{$prop};
            unless $val.defined {
                if $schema-prop<type> eq <array> {
                    $val = [];
                } elsif $schema-prop<type> eq <object> || is-subrecord($schema-prop<type>) {
                    $val = {};
                    if $schema-prop<subtype> && $schema-prop<subtype> eq <ref> {
                        $val<ref> = '';
                    }
                } elsif $prop eq 'vocabulary' {
                    $val = '/vocabularies/1';
                } elsif $schema-prop<type> eq <string> {
                    $val = '';
                }
            }

            @subrecord.push(FormField.new(:$prop,
                                          :parent(self),
                                          :depth(self.depth + 1),
                                          :schema($schema-prop),
                                          :$label,
                                          :value($val)));
        }

        Subrecord.new(:fields(@subrecord));
    }

    method new-subrecord($schema-name?) {
        my %props;
        my @prop-names;
        my $jsonmodel;
        my $rec = {};

        if $!schema<type> eq <array> {
            if $!schema<items><type> && $!schema<items><type> ~~ <string> {
                %props = item => $!schema<items>;
                $rec = '';
            } elsif $!schema<items><type> && is-subrecord($!schema<items><type>) {
                $jsonmodel = subrecord-type($!schema<items><type>);
                if $jsonmodel ~~ Iterable {
                    if $schema-name && $schema-name ~~ any |$jsonmodel {
                    $jsonmodel = $schema-name;
                    } else {
                        return;
                    }
                }
                my $schema = schemas(:name($jsonmodel));
                %props = $schema<properties>;
                @prop-names = |$schema<property_list>;
            } else {
                %props = ($!schema<items><properties> || {item => $!schema<items>});
            }
        } elsif $!schema<type> eq <object> {
            %props = $!schema<properties>;
        } elsif is-subrecord($!schema<type>) {
            $jsonmodel = subrecord-type($!schema<type>);
            my $schema = schemas(:name($jsonmodel));
            %props = $schema<properties>;
            @prop-names = |$schema<property_list>;
        } else {
            return;
        }

        my $subrecord = self.build-subrecord-with(%props, @prop-names, $rec);

        $rec = $subrecord.fields.map({ .prop => .value }).Hash;
        if all $rec.map(*.key) eq <item> {
            $rec = $rec.map(*.value);
        } elsif $jsonmodel {
            $rec<jsonmodel_type> = $jsonmodel;
        }

        if $!subrecord-ix.defined {
            @!subrecords.splice($!subrecord-ix, 0, $subrecord);
            $!value.splice($!subrecord-ix, 0, $rec);
        } else {
            $!subrecord-ix = @!subrecords.elems;
            @!subrecords.push($subrecord);
            $!value.push($rec);
        }
    }

    method has-subrecords {
        so @!subrecords;
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

    method delete-current-subrecord-or-all {
        if $!subrecord-ix {
            self.delete-subrecord($!subrecord-ix);
            'current';
        } else {
            @!subrecords = [];
            $!value = [];
            'all';
        }
    }

    method delete-subrecord($ix) {
        @!subrecords.splice($ix, 1);
        $!value.splice($ix, 1);
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
                    if (my $k = $val.keys.first({ $_ !~~ /^ '_'/ })) {
                        $val = ansi($k ~ ': ' ~ $val{$k}, "bold $value-style");
                    } else {
                        $val = '--';
                    }
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
                my $p = $!prop;
                if $val.elems == 1 {
                    $p ~~ s/'s' $//;
                }
                $val = ansi($val.elems.Str, "bold $value-style") ~ ' ' ~ $p;
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
        my $prop = self.open-for-update ?? ansi($!prop, 'bold') !! $!prop;
        my $width = self.open-for-update  ?? self.prop-width + 8 !! self.prop-width;

        sprintf("%{$width}s{'  ' x $!depth} $cursor %s", $prop, $val);
    }
}

class Subrecord {
    has FormField @.fields;

    method clone {
        Subrecord.new(:fields(@!fields.map(*.clone)));
    }
}

class Editor {
    has %.json; # the parsed json of the record
    has $.schema; # the JSONModel schema for the record's type
    has FormField @.fields; # a FormField for each editable property in the schema
    has $.selected-field-ix = 0; # the array index of the currently selected field
    has $.cursor-offset;
    has $.top-field-ix = 0;
    has Promise $.message-timer-cancel = Promise.new;
    has @.record-stack; # previously loaded records stacked so they can be returned to
    has @.mode-stack; # command modes stacked

    has $.number-of-display-lines = term_lines() - 6;
    has $.first-display-line = 3;

    submethod TWEAK {
        self.init;
    }

    method init(%json?, :$previous) {
        if %json {
            if %!json {
                @!record-stack.push(%!json.clone);
            }
            %!json = %json;
        } elsif $previous {
            if @!record-stack {
                %!json = @!record-stack.pop;
            } else {
                self.message('No previous record to load');
                return;
            }
        } elsif !%!json {
            return;
        }

        $!schema = schemas(:name(%!json<jsonmodel_type>));
        return unless $!schema;

        $!selected-field-ix = 0;
        $!top-field-ix = 0;

        self.load-fields;

        True;
    }

    method new-for-type($jsonmodel-type, $uri) {
        my $editor = Editor.new;
        $editor.create-record($jsonmodel-type, :$uri);
        $editor;
    }

    method create-record($jsonmodel-type, :$uri is copy) {
        my $schema = schemas(:name($jsonmodel-type));

        unless $uri {
            $uri = $schema<uri>;
            if $uri ~~ /':repo_id'/ {
                unless %!json {
                    self.message("Can't find a repo_id for $uri");
                    return;
                }
                %!json<uri> ~~ /\/repositories\/(\d+)/;
                my $repo_id = $0.Str;
                $uri ~~ s/':repo_id'/$repo_id/;
            }
        }

        my %rec = jsonmodel_type => $jsonmodel-type, uri => $uri;

        for $schema<properties>.kv -> $prop, %def {
            next if %def<readonly>;
            next if EDIT_SKIP_PROPS.grep($prop);

            given %def<type> {
                when <string>  { %rec{$prop} = %def<default> // ''; }
                when <array>   { %rec{$prop} = []; }
                when <boolean> { %rec{$prop} = %def<default>; }
                when <integer> { %rec{$prop} = %def<default>; }
                when <object>  { %rec{$prop} = {}; }
            }

            if $prop eq 'vocabulary' {
                %rec{$prop} = '/vocabularies/1';
            }
        }

        self.init(%rec);
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
            next if EDIT_SKIP_PROPS.grep($prop);

            # this json cycling bizzo is trying to break refs (like a deep clone) - probably not necessary
            @!fields.push(FormField.new(:$prop, :schema($schema_prop), :value(from-json to-json %!json{$prop})));
        }

        self.set-prop-width;
    }

    method set-prop-width {
        FormField.prop-width = @!fields.map(*.prop.chars).max;
        $!cursor-offset = FormField.prop-width + 3;
    }

    method field-for-error-ref($error-ref) {
        return unless $error-ref;

        my @ref = $error-ref.split('/');

        my $field = @!fields.first: *.prop eq @ref[0];
        @ref.shift;

        for @ref -> $ref {
            last unless $field;

            if $ref ~~ /^ \d $/ {
                $field = $field.subrecords[$ref];
            } else {
                if $field ~~ Subrecord {
                    $field = $field.fields.first: *.prop eq $ref;
                } else {
                    $field = $field.subrecords[0].fields.first: *.prop eq $ref;
                }
            }
        }

        $field;
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

        self.set-prop-width;
    }

    method draw-remove-subrecord {
        if (my $open-ix = self.ix-of-field-with-open-subrecord).defined {
            $!selected-field-ix = $open-ix;
        }

        self.field.close-subrecord;

        self.remove-subrecord-fields;

        self.draw-form;
    }

    method draw-next-subrecord {
        return unless self.field.subrecords;

        self.remove-subrecord-fields;

        @!fields.splice($!selected-field-ix + 1, 0, self.field.next-subrecord.fields);

        self.set-prop-width;

        self.draw-form;
    }

    method draw-current-subrecord {
        return unless self.field.subrecords;

        self.remove-subrecord-fields;

        @!fields.splice($!selected-field-ix + 1, 0, self.field.current-subrecord.fields);

        self.set-prop-width;

        self.draw-form;
    }

    method revert-value {
        self.set-value(self.field.original-value);

        if self.field.original-subrecords {
            self.field.revert-subrecords;
        }
    }

    method set-value($value) {
        self.field.set-value($value);
    }

    method with-cursor-lock(&block) {
        ENTER $!message-timer-cancel.keep;
        LEAVE {
            $!message-timer-cancel = Promise.new;
            self.set-message-cancel-timer;
        }

        &block();
    }

    method set-message-cancel-timer {
        start react {
            whenever $!message-timer-cancel { done; }
            whenever Promise.in(8) { print-at(term_lines() - 1, 2, '', :clear); done; }
        }
    }

    method clear-message {
        self.message('');
    }

    method message($s, :$sticky) {
        $!message-timer-cancel.keep;
        $!message-timer-cancel = Promise.new;

        print-at(term_lines() - 1, 2, ansi($s.gist, 'yellow'), :clear);

        self.set-message-cancel-timer unless $sticky;
    }

    method field {
        @!fields[$!selected-field-ix];
    }

    method move-cursor(Int $d) {
        my $old-ix = $!selected-field-ix;
        my $new-ix = $!selected-field-ix + $d;
        my $open-subrecord-ix = self.ix-of-field-with-open-subrecord;

        if $new-ix < 0 || $new-ix >= @!fields.elems
                       || ($open-subrecord-ix.defined && $new-ix < $open-subrecord-ix)
                       || ($open-subrecord-ix.defined && $new-ix > $open-subrecord-ix + self.field-with-open-subrecord.current-subrecord.fields) {
            print BEL;
        } elsif $new-ix < $!top-field-ix {
            $!selected-field-ix = $new-ix;
            self.scroll-form(-1);
        } elsif $new-ix > $!number-of-display-lines + $!top-field-ix {
            $!selected-field-ix = $new-ix;
            self.scroll-form(1);
        } else {
            self.field.open-for-update = False;
            self.field.value-ix = Nil;

            $!selected-field-ix = $new-ix;
            self.draw-field($old-ix);
            self.draw-field;
        }
    }

    method scroll-form(Int $d) {
        $!top-field-ix += $d;
        self.draw-form;
    }

    method draw-ref-search {
        my $type = self.field.schema<type>;
        if $type ~~ Array {
            for |$type -> $t {
                $t<type> ~~ s/^ 'JSONModel(:' (\w+) ') uri' $/$0/;
            }
            $type = $type.map(*.<type>).Array;
        } else {
            $type ~~ s/^ 'JSONModel(:' (\w+) ') uri' $/$0/;
        }

        self.push-mode(self.linker-mode($type,
                                        self.field-display-line,
                                        $!cursor-offset + self.field.depth * 2 + 2));
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
            print-at($line, 1, $field.render(:selected($ix == $!selected-field-ix)), :fill);

            if $field.parent {
                self.draw-field(self.ix-for-field($field.parent));
            }
        } else {
            print-at($line, 1, '', :clear);
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
        self.draw-form;
    }

    method draw-header {
        my Bool $new-record = not %!json<uri> ~~ / \d $/;

        my $label = (%!json<uri>, $new-record ?? 'NEW' !! label-for-json(%!json)).join(' | ');
        $label = ('.' x @!record-stack) ~ ' ' ~ $label;

        my $last-update = $new-record ?? '' !! '  ' ~ ansi(%!json<last_modified_by> ~ ' @ ' ~ DateTime.new(%!json<user_mtime>).local, 'cyan');

        print-at(1, 2, ansi($label, 'bold') ~ $last-update, :clear);
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

        self.push-mode(self.main-mode);

        print-at(term_lines(), 1, '', :clear);

        "Closed form for {%!json<uri>}";
    }

    method current-mode {
        @!mode-stack.tail;
    }

    method push-mode(CommandMode $mode) {
        @!mode-stack.push($mode);
        $mode.run;
        @!mode-stack.pop;
        if self.current-mode {
            self.current-mode.help;
        }
    }

    method main-mode {
        my $mode = CommandMode.new(:name('Main'));

        $mode.add-sub-mode(<selected>, <green>, :set(-> { !self.field.open-for-update }));

        $mode.add-sub-mode('open bool', <lilac>, :set(-> { self.field.open-for-update && self.field.schema<type> eq 'boolean' }));
        $mode.add-sub-mode('open enum', <lilac>, :set(-> { self.field.open-for-update && (self.field.schema<enum> || self.field.schema<dynamic_enum>) }));
        $mode.add-sub-mode('open value', <lilac>, :set(-> { self.field.open-for-update && self.field.schema<type> eq any(<string integer date>) &&
                                                            !(self.field.schema<enum> || self.field.schema<dynamic_enum>)}));
        $mode.add-sub-mode('open sub', <lilac>, :set(-> { self.field.open-for-update && self.field.schema<type> eq 'array' && self.field.value.elems > 1 }));

        $mode.add-sub-mode(<add>, <yellow>, :set(-> { self.field.schema<type> eq <array> }));
        $mode.add-sub-mode(<edited>, <cyan>, :set(-> { self.field.updated }));
        $mode.add-sub-mode(<subrecord>, <orange>, :set(-> { self.field-with-open-subrecord }));
        $mode.add-sub-mode(<ref>, <blue>, :set(-> { self.field.prop eq <ref> }));
        $mode.add-sub-mode(<stack>, <magenta>, :set(-> { @!record-stack }));
        $mode.add-sub-mode(<image>, <purple>, :set(-> { self.field.value ~~ Str && self.field.value ~~ /^ 'http' .+? '.' ('jpg' | 'png') $/ }), :color(<yellow>));


        $mode.add-sub-command('selected', ' ', 'SPACE', 'Open for update',
                              -> $k {
                                     my $prop = self.field.schema;

                                     self.field.open-for-update = True;

                                     if self.field.prop eq <ref> || is-record-ref($prop<type>) {
                                         self.draw-ref-search;
                                         self.field.open-for-update = False;
                                     } elsif $prop<type> eq <array> | <object> || is-subrecord($prop<type>) {
                                         if self.field.value && !self.field.label && %!json<uri> ~~ / \d $/ {
                                             if $prop<subtype> ~~ <ref> || ($prop<items> && $prop<items><subtype> ~~ <ref>) {
                                                 my $resp = from-json client.get(%!json<uri>, ('resolve[]=' ~ self.field.prop,));
                                                 if $resp<error> {
                                                     self.message($resp<error>);
                                                 } else {
                                                     my %ref-map;

                                                     sub walk($node) {
                                                         if $node ~~ Associative {
                                                             if $node<ref> && $node<_resolved> {
                                                                 %ref-map{$node<ref>} = $node<_resolved>;
                                                             } else {
                                                                 walk($_) for $node.values;
                                                             }
                                                         } elsif $node ~~ Positional {
                                                             walk($_) for @$node;
                                                         }
                                                     }

                                                     walk($resp);

                                                     for @!fields { .set-labels-for(%ref-map); }
                                                 }
                                             }
                                         }
                                         self.draw-next-subrecord;
                                     }

                                     self.draw-field;
                                 });

        $mode.add-sub-command('open bool', ' ', 'SPACE', 'Toggle',
                              -> $k {
                                     self.set-value(!self.field.value);
                                     self.draw-field;
                                 });

        $mode.add-sub-command('open enum', ' ', 'SPACE', 'Next value',
                              -> $k {
                                     my $prop = self.field.schema;
                                     if $prop<enum> {
                                         my $next-ix = $prop<enum>.first(self.field.value, :k) + 1;
                                         $next-ix %= $prop<enum>.elems;
                                         self.set-value($prop<enum>[$next-ix]);
                                         self.draw-field;
                                     } elsif $prop<dynamic_enum> {
                                         my $enum = enum-by-name($prop<dynamic_enum>);
                                         my @values = |$enum<values>;
                                         my $current-value-ix = @values.first(self.field.value, :k);
                                         my $next-ix = $current-value-ix.defined ?? $current-value-ix + 1 !! 0;
                                         $next-ix %= @values.elems;
                                         self.set-value(@values[$next-ix]);
                                         self.field.set-label;
                                         self.draw-field;
                                     }
                                 });

        $mode.add-sub-command('open value', ' ', 'SPACE', 'Edit',
                              -> $k {
                                     my $val = self.field.value // '';
                                     if $val.chars > term_cols() - $!cursor-offset - 20 || $val ~~ /\n/ {
                                         save_tmp(self.field.value, :file-name('edit.txt'));
                                         if edit(tmp_file('edit.txt')) {
                                             self.set-value(slurp(tmp_file('edit.txt')).chomp);
                                             self.message('Edits applied');
                                             self.draw-field;
                                         } else {
                                             self.message('No edits');
                                         }
                                         run <tput civis>;
                                     } else {
                                         my $coo = self.field.depth * 2 + 1;

                                         self.push-mode(self.line-editor-mode($!first-display-line + $!selected-field-ix - $!top-field-ix,
                                                                              $!cursor-offset + $coo,
                                                                              :value(self.field.value)));
                                         self.draw-field;
                                     }
                                 });

        $mode.add-sub-command('open sub', ' ', 'SPACE', 'Next subrecord',
                              -> $k {
                                     self.draw-next-subrecord;
                                 });

        $mode.add-sub-command('edited', "\t", 'TAB', 'Revert',
                          -> $k {
                                 self.revert-value;
                                 if self.field.subrecord-open {
                                     self.draw-remove-subrecord
                                 } else {
                                     self.draw-field;
                                 }
                             });

        $mode.add-sub-command('add', 'a', 'Add subrecord',
                          -> $k {
                                 if self.field.value ~~ Iterable {
                                     my $types = jsonmodel-object-types-for-schema(self.field.schema);
                                     if $types && $types ~~ Iterable {
                                         # the subrecord can have more than one type - get the user to choose one
                                         self.push-mode(self.new-subrecord-for-types-mode($types, self.field-display-line, $!cursor-offset + self.field.depth * 2 + 2));
                                     } else {
                                         self.field.new-subrecord;
                                         self.draw-current-subrecord;
                                     }
                                 }
                             });

        $mode.add-sub-command('subrecord', 'c', 'Close subrecord',
                          -> $k {
                                 self.draw-remove-subrecord;
                             });

        $mode.add-sub-command('ref', 'g', 'Goto link',
                          -> $k {
                                 if self.field.prop eq <ref> {
                                     self.load-record(self.field.value);
                                 } else {
                                     self.message("Can only go to uris in ref fields");
                                 }
                             });

        $mode.add-sub-command('ref', 'n', 'New record',
                          -> $k {
                                 if self.field.prop eq <ref> {
                                     self.create-record(ref-record-type(self.field.schema<type>));
                                     self.draw-page;
                                 } else {
                                     self.message("Can only go to uris in ref fields");
                                 }
                             });

        $mode.add-sub-command('stack', 'b', 'Back to previous record',
                          -> $k {
                                 self.load-previous-record;
                             });

        $mode.add-sub-command('image', 'v', 'View image',
                          -> $k {
                                 if self.field.value ~~ /^ 'http' .+? '.' ('jpg' | 'png') $/ {
                                     if inline_image_supported() {
                                         self.message("Showing: {self.field.value}", :sticky);
                                         my $width = term_cols() - $!cursor-offset - 40;
                                         my $height = term_lines() - 10;
                                         if (my $img = image-for-url(self.field.value, :$width, :$height)) {
                                             print-at(5, $!cursor-offset + 20, $img, :raw);
                                             self.push-mode(self.image-viewer-mode);
                                         } else {
                                             self.message("Sorry, that image didn't dowmload");
                                         }
                                     } else {
                                         self.message('Sorry, image viewing only available with iTerm2');
                                     }
                                 } else {
                                     self.message('The current field is not an image link');
                                 }
                             });


        $mode.add-command('d', 'Delete',
                          -> $k {
                                 if self.field.has-subrecords {
                                     if self.field.delete-current-subrecord-or-all eq 'all' {
                                         self.message("Deleted all {self.field.prop}");
                                     } else {
                                         self.message("Deleted item from {self.field.prop}");
                                         self.draw-next-subrecord;
                                     }
                                 } else {
                                     self.set-value('');
                                 }
                                 self.draw-field;
                             });

        $mode.add-command('s', 'Save',
                          -> $k {
                                 for @!fields.grep(*.updated && !*.parent) -> $field {
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

                                         if $k eq <identifier> && self.field-for-error-ref(<id_0>) {
                                             for <id_0 id_1 id_2> -> $id {
                                                 my $field = self.field-for-error-ref($id);
                                                 if $field.value {
                                                 } else {
                                                     $field.error = $v.join(', ');
                                                 }
                                             }
                                         } else {
                                             if (my $err-field = self.field-for-error-ref($k)) {
                                                 $err-field.error = $v.join(', ');
                                             }
                                         }
                                     }

                                     self.draw-form;
                                     self.message('Error - record not saved: ' ~ @err-msg.join(' | '));
                                 } else {
                                     if (my $open-subrecord-ix = self.ix-of-first-field-with-open-subrecord).defined {
                                         $!selected-field-ix = $open-subrecord-ix;
                                     }

                                     # if it was a create then let's grab the new uri
                                     if %resp<status> eq 'Created' {
                                         %!json<uri> = %resp<uri>;
                                     }

                                     # reload json after the update
                                     %resp = from-json client.get(%!json<uri>);

                                     if %resp<error> {
                                         self.message('Error reloading after successful save: ' ~ %resp<error>.raku);
                                     } else {
                                         %!json = %resp;
                                         self.load-fields;
                                         self.draw-header;
                                         self.draw-form;
                                         self.message('Saved');
                                     }
                                 }
                             });

        $mode.add-command(UP_ARROW, "\c[UPWARDS ARROW] \c[DOWNWARDS ARROW]", 'Cursor',
                          -> $k {
                                 self.move-cursor(-1);
                             });

        $mode.add-command(DOWN_ARROW,
                          -> $k {
                                 self.move-cursor(1);
		                         });

        $mode.add-command(RIGHT_ARROW, "\c[LEFTWARDS ARROW] \c[RIGHTWARDS ARROW]", 'Scroll',
                          -> $k {
                                 if $!top-field-ix + 1 >= self.max-top-field-ix {
                                     print BEL;
                                 } elsif $!top-field-ix + 1 > $!selected-field-ix {
                                     print BEL;
                                 } else {
                                     self.scroll-form(1);
                                 }
		                         });

        $mode.add-command(LEFT_ARROW,
                          -> $k {
                                 if $!top-field-ix < 1 {
                                     print BEL;
                                 } elsif $!top-field-ix + 1 < $!selected-field-ix - $!number-of-display-lines + 2 {
                                     print BEL;
                                 } else {
                                     self.scroll-form(-1);
                                 }
		                         });

        $mode.add-command(/\d/, '1 2 +', 'Page',
                          -> $k {
                                 my $ix = $!number-of-display-lines * ($k - 1);
                                 if $ix > +@!fields || self.field-with-open-subrecord {
                                     print BEL;
                                 } else {
                                     $!top-field-ix = $ix;
                                     $!selected-field-ix = $ix;
                                     self.draw-form;
                                 }
                             });

        $mode.add-command('q', 'Quit', -> $k { last; });


        $mode.add-command('@',
                          -> $k {
                                 self.push-mode(self.diagnostic-mode);
                             });

        $mode;
	  }

    method line-editor-mode($line, $col, :$value) {
        my $mode = CommandMode.new(:name('Editor'), :no-key);

        $mode.add-command(Any, 'Type', 'to edit',
                          -> $k {
                                 self.with-cursor-lock: {
                                     self.set-value(line-editor($line, $col, :$value));
                                 }
                                 last;
                             });

        if $value {
            $mode.add-command(Any, "\c[UPWARDS ARROW]", 'Current value', -> $k {});
        }
        $mode.add-command(Any, 'ENTER', 'Set edited value', -> $k {});

        $mode;
    }

    method image-viewer-mode {
        my $mode = CommandMode.new(:name('Image viewer'));

        $mode.add-command(Any, 'ANY KEY', 'Exit viewer',
                          -> $k {
                                 self.clear-message;
                                 self.draw-form;
                                 last;
                             });

        $mode;
    }

    method diagnostic-mode {
        my $mode = CommandMode.new(:name('Diagnostics'));

        $mode.add-command('q', 'Quit',
                          -> $k {
                                 last;
                             });

        $mode.add-command('m', 'Field schema',
                          -> $k {
                                 page(pretty to-json self.field.schema);
                             });

        $mode.add-command('M', 'Record schema',
                          -> $k {
                                 page(pretty to-json self.schema);
                             });

        $mode.add-command('v', 'Value',
                          -> $k {
                                 page(pretty to-json self.field.value);
                             });

        $mode.add-command('V', 'Original value',
                          -> $k {
                                 page(pretty to-json self.field.original-value);
                             });

        $mode.add-command('j', 'Field JSON',
                          -> $k {
                                 page(pretty to-json %!json{self.field.prop});
                             });

        $mode.add-command('J', 'Record JSON',
                          -> $k {
                                 page(pretty to-json %!json);
                             });

        $mode.add-command('u', 'Subrecords',
                          -> $k {
                                 page(pretty to-json self.field.subrecords.raku);
                             });

        $mode;
    }

    method linker-mode($type, $line, $col) {
        my %search;
        my $ix = 0;
        my $page = 1;
        my $page-size = 10;
        my $q = '';

        print-at($line, $col, ansi('Search: ', 'green') ~ ansi('_', 'bold'), :fill);

        sub absolute-ix {
            ($page - 1) * $page-size + $ix;
        }

        sub message-for-search(%search) {
            if %search<results> {
                my $msg = "{absolute-ix() + 1} of {%search<total_hits>}: {%search<results>[$ix]<uri>}";
                if %search<results>[$ix]<title> {
                    $msg ~= ' | ' ~ %search<results>[$ix]<title>;
                }
                self.message($msg, :sticky);
            } else {
                self.message('No hits', :sticky);
            }
        }

        my $mode = CommandMode.new(:name('Ref linker'));

        $mode.add-command(/^ (\w | $(DELETE)) $/, 'Type', 'to search',
                          -> $k {
                              $ix = 0;
                              $page = 1;
                              if $k ~~ /^ \w $/ {
                                  $q ~= $k;
                              } elsif $k eq DELETE {
                                  $q.=substr(0, *-1) if $q;
                              }
                              if $q {
                                  run <stty -echo>;
                                  %search = self.search-type($type, $q, :$page, :$page-size);
                                  run <stty echo>;
                                  message-for-search(%search);
                                  print-at($line, $col + 8, ansi($q ~ '_', 'bold') ~ '  ' ~ %search<total_hits> ~ ' hits', :fill);
                              } else {
                                  %search = Empty;
                                  self.clear-message;
                                  print-at($line, $col + 8, ansi($q ~ '_', 'bold'), :fill);
                              }
                          });

        $mode.add-command("\t", 'TAB', 'Exit',
                          -> $k {
                                 self.message("Exited linker");
                                 last;
                             });

        $mode.add-command(' ', 'SPACE', 'Next result',
                          -> $k {
                                 if %search<results> {
                                     $ix++;
                                     if absolute-ix() >= %search<total_hits> {
                                         $ix = 0;
                                         $page = 1;
                                         %search = self.search-type($type, $q, :$page, :$page-size);
                                     } elsif $ix >= $page-size {
                                         $ix = 0;
                                         $page++;
                                         %search = self.search-type($type, $q, :$page, :$page-size);
                                     }
                                     message-for-search(%search);
                                 } else {
                                     self.message('No hits');
                                 }
                             });

        $mode.add-command(/\n/, 'ENTER', 'Link current result',
                          -> $k {
                                 if %search<results> {
                                     self.set-value(%search<results>[$ix]<uri>);
                                     self.field.label = %search<results>[$ix]<title>;

                                     self.draw-field;
                                     self.message('Linked ' ~ self.field.value);
                                     last;
                                 } else {
                                     self.message('No result to link');
                                 }
                             });

        $mode.add-command('`', 'BACKTICK', 'Enter link manually',
                          -> $k {
                                 self.push-mode(self.line-editor-mode($line, $col - 1));
                                 self.field.label = '';
                                 self.message("Link entered manually");
                                 last;
                             });

        $mode;
    }

    method new-subrecord-for-types-mode(@types, $line, $col) {
        my $ix = 0;
        print-at($line, $col, ansi('Select a subrecord type: ', 'green') ~ ansi(@types[$ix], 'bold'), :fill);

        my $mode = CommandMode.new(:name('Select subrecord type'));

        $mode.add-command('q', 'Quit',
                          -> $k {
                                 self.draw-field;
                                 last;
                                });

        $mode.add-command(' ', 'SPACE', 'Next type',
                          -> $k {
                                 $ix = ($ix + 1) % @types;
                                 print-at($line, $col, ansi('Select a subrecord type: ', 'green') ~ ansi(@types[$ix], 'bold'), :fill);
                             });

        $mode.add-command(/\n/, 'ENTER', 'Select type',
                          -> $k {
                                 self.field.new-subrecord(@types[$ix]);
                                 self.draw-current-subrecord;
                                 last;
                             });

        $mode;
    }

    method search-type($type, $q, :$page = 1, :$page-size = 10) {
        my @args = "page=$page", "q=$q", "page_size=$page-size";

        for |$type -> $t {
            @args.push("type[]=$t");
        }

        my %resp = from-json client.get(SEARCH_URI, @args);

        if %resp<error> {
            self.message("Error searching for $type with '$q': " ~ %resp<error>);
        }

        %resp;
    }
}

class SubMode {...}

class CommandMode {
    has $.name;
    has CommandKey @.command-keys;
    has Str @.active-sub-modes;
    has SubMode @.sub-modes;
    has Bool $.no-key;

    method add-sub-mode($name, $color, :&set, :&unset) {
        @!sub-modes.push(SubMode.new(:$name, :$color, :set-trigger(&set), :unset-trigger(&unset)));
    }

    multi method add-command($key-match, $label, $description, &block) {
        @!command-keys.push(CommandKey.new(:$key-match, :$label, :$description, :&block));
    }

    multi method add-command($key-match, $description, &block) {
        @!command-keys.push(CommandKey.new(:$key-match, :$description, :&block));
    }

    multi method add-command($key-match, &block) {
        @!command-keys.push(CommandKey.new(:$key-match, :&block));
    }

    multi method add-command(CommandKey $cmd) {
        @!command-keys.push($cmd);
    }

    multi method add-sub-command($sub-mode, $key-match, $label, $description, &block) {
        @!command-keys.push(CommandKey.new(:$sub-mode, :$key-match, :$label, :$description, :&block));
    }

    multi method add-sub-command($sub-mode, $key-match, $description, &block) {
        @!command-keys.push(CommandKey.new(:$sub-mode, :$key-match, :$description, :&block));
    }

    method active-keys {
        @!command-keys.grep(-> $ck { !$ck.sub-mode || @!active-sub-modes && $ck.sub-mode eq any(@!active-sub-modes) });
    }

    method run {
        self.help();

        loop {
            for @!sub-modes -> $sub-mode {
                if $sub-mode.unset-trigger && $sub-mode.unset-trigger.() {
                    self.unset-sub-mode($sub-mode.name);
                } elsif $sub-mode.set-trigger.() {
                    self.set-sub-mode($sub-mode.name);
                } else {
                    self.unset-sub-mode($sub-mode.name);
                }
            }

            my $k = $!no-key ?? Any !! get-key-in;

            if (my $cmd = self.active-keys.first(-> $ck {$k ~~ $ck.key-match})) {
                $cmd.block.($k);
            } else {
                print BEL;
            }
        }
    }

    method set-sub-mode($sub-mode) {
        my @orig = @!active-sub-modes.clone;

        @!active-sub-modes.push($sub-mode);
        @!active-sub-modes.=unique;

        unless @orig eqv @!active-sub-modes {
            self.help;
        }
    }

    method unset-sub-mode($sub-mode?) {
        my @orig = @!active-sub-modes.unique;

        if $sub-mode {
            @!active-sub-modes.=grep(* ne $sub-mode);
        } else {
            @!active-sub-modes = Empty;
        }

        unless @orig eqv @!active-sub-modes {
            self.help;
        }
    }

    method help {
        my $sub-label = @!active-sub-modes.map(-> $sm { ansi($sm, @!sub-modes.first({ .name eq $sm }).color ~ ' bold')  }).join(' ');

        my $help-txt;

        for self.active-keys.grep(*.description) -> $k {
            my $label = $k.label // $k.key-match;
            $help-txt ~= ' | ' if $help-txt;
            my $color = $k.sub-mode ?? @!sub-modes.first({ .name eq $k.sub-mode }).color ~ ' bold' !! 'bold';

            if $label.fc eq $k.description.substr(0,1).fc {
                $help-txt ~= ansi($label.uc, $color) ~ $k.description.substr(1);
            } else {
                $help-txt ~= ansi($label, $color) ~ ' ' ~ $k.description;
            }
        }

        my $mode-label = ansi($!name, 'bold');
        if $sub-label {
            $mode-label ~= ' (' ~ $sub-label ~ ')';
        }
        $mode-label ~= ': ';

        print-at(term_lines(), 2, $mode-label ~ $help-txt, :clear);
    }
}

class SubMode {
    has $.name;
    has $.color;
    has &.set-trigger;
    has &.unset-trigger;
}

class CommandKey {
    has $.key-match;
    has $.label;
    has $.description;
    has Str $.sub-mode;
    has &.block;
}
