use Functions;

use Terminal::LineEditor;
use Terminal::LineEditor::RawTerminalInput;
use JSON::Tiny;

class FormField {
    has $.prop;
    has $.parent-prop;
    has $.schema;
    has $.value is rw;
    has $.original-value;
    has Bool $.open-for-update is rw = False;
    has Bool $.subrecord-open is rw = False;
    has Int $.value-ix is rw;
    has Str $.label is rw;

    submethod TWEAK {
        # storing it as json - annoying but deep structures are passed by ref
        # so get mutated when they change in $!value - tried deepmap, no go
        $!original-value = to-json $!original-value || $!value;
        self.set-label;
    }

    my $.prop-width;

    method original-value {
        from-json $!original-value;
    }

    method set-label {
        if $!schema<dynamic_enum> && $!value {
            $!label = enum-by-name($!schema<dynamic_enum>)<value_translations>{$!value};
        }
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

    method updated {
        my $ov = self.original-value;
        if $!value ~~ Hash {
            $!value !eqv $ov;
        } elsif $!value ~~ Iterable && $!value.head ~~ Hash {
            # $!value might have been populated with _resolveds
            $!value.map({ %(.grep({ .key ne <_resolved> }))}).Array !eqv $ov;
        } else {
            $!value !eqv $ov;
        }
    }

    method render(:$selected, :$subrecord-ix) {
        my $value-style = '';
        if $!open-for-update {
            $value-style = 'green';
        } elsif self.updated {
            $value-style = 'cyan';
        }

        my $val = $!value.clone;

        if !$val.defined || ($val ~~ Str && $val eq '') {
            $val = ansi('--', $value-style);
        } elsif $val ~~ Hash {
            if $val.elems > 1 {
                $val = ansi($!prop, "bold $value-style") ~ " {$val.elems} properties";
            } else {
                $val = ansi($val.head.key ~ ': ' ~ $val.head.value, "bold $value-style");
            }
        } elsif $val ~~ Iterable {
            if $!value-ix.defined {
                my $item = $val[$!value-ix];
                if $item<ref> {
                    if $item<_resolved> {
                        my $label = self.label-for-json($item<_resolved>);
                        $val = ansi($item<ref> ~ ' | ' ~ $label, "bold $value-style");
                    } else {
                        $val = ansi($item<ref>, "bold $value-style");
                    }
                } else {
                    $val = ansi($item.gist, "bold $value-style");
                }
            } elsif $!subrecord-open {
                $val = ansi("{$subrecord-ix + 1} of {$val.elems}", "bold $value-style") ~ ' ' ~ $!prop;
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

        my $cursor = $selected ?? ansi('>>', 'bold green') !! '::';

        if $!parent-prop {
            sprintf("%{self.prop-width}s    $cursor %s\n", $!prop, $val);
        } else {
            sprintf("%{self.prop-width}s $cursor %s\n", $!prop, $val);
        }
    }
}

class Editor {
    has %.json; # the parsed json of the record
    has $.schema; # the JSONModel schema for the record's type
    has FormField @.fields; # a FormField for each editable property in the schema
    has $.selected-field-ix = 0; # the array index of the currently selected field
    has @.subrecords; # a FormField array for each sub-record in the selected field 
    has $.subrecord-ix; # the array index of the currently selected subrecord
    has $.cursor-offset;
    has $.top-field-ix = 0;
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
        $!schema = schemas(:name(%!json<jsonmodel_type>));

        return unless $!schema;

        my @props = |$!schema<property_list>;
        my $longest = @props>>.chars.max;
        my $max_val_length = term_cols() - $longest - 20;
        $!cursor-offset = $longest + 3;
        FormField.prop-width = $longest;

        self.load-fields;
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
        unless self.field.schema<type> eq 'array' {
            self.message(self.field.prop ~ ' does not contain subrecords');
            return;
        }

        @!subrecords = Empty;

        my @ov = |self.field.original-value;

        for |self.field.value -> $rec {
            my @subrecord;

            my @prop-names;
            my %props;

            if $rec<jsonmodel_type> {
                my $item-schema = schemas(:name($rec<jsonmodel_type>));
                @prop-names = |$item-schema<property_list>;
                %props = $item-schema<properties>;
            } else {
                @prop-names = self.field.schema<items><properties>.keys;
                %props = self.field.schema<items><properties>;
            }

            for @prop-names -> $prop {
                next if $prop ~~ /^ '_' /;
                my $schema-prop = %props{$prop};
                next if $schema-prop<readonly>;
                next if @!skip_props.grep($prop);

                my $label = ($prop eq <ref> && $rec<_resolved>) ?? self.label-for-json($rec<_resolved>) !! '';

                @subrecord.push(FormField.new(:$prop,
                                              :parent-prop(self.field.prop),
                                              :original-value(@ov[@!subrecords.elems]{$prop}),
                                              :schema($schema-prop),
                                              :$label,
                                              :value($rec{$prop})));
            }

            @!subrecords.push(@subrecord);
        }

        self.draw-remove-subrecord;
        self.draw-next-subrecord;
        self.draw-help(@subrecord-help, :add);
    }

    method field-with-open-subrecord {
        @!fields.first: *.subrecord-open;
    }

    method ix-of-field-with-open-subrecord {
        @!fields.first: *.subrecord-open, :k;
    }

    method draw-remove-subrecord {
        if (my $open-ix = self.ix-of-field-with-open-subrecord).defined {
            $!selected-field-ix = $open-ix;
        }

        $!subrecord-ix = Nil;
        for @!fields { .subrecord-open = False };
        @!fields.=grep({ !.parent-prop });
        self.draw-form;
        self.draw-help;
    }

    method draw-next-subrecord {
        return unless @!subrecords;

        if $!subrecord-ix.defined {
            $!subrecord-ix++;
        } else {
            $!subrecord-ix = 0;
        }

        $!subrecord-ix = $!subrecord-ix % @!subrecords;

        @!fields.=grep({ !.parent-prop });

        self.field.subrecord-open = True;

        @!fields.splice($!selected-field-ix + 1, 0, @!subrecords[$!subrecord-ix]);

        self.draw-form;
    }

    method revert-value {
        self.set-value(self.field.original-value);
    }

    method set-value($value) {
        self.field.value = $value;
        if $!subrecord-ix.defined {
            self.field-with-open-subrecord.value[$!subrecord-ix]{self.field.prop} = $value;
        }
    }

    method message($s) {
        print-at(term_lines() - 1, 3, ansi($s.gist, 'yellow'), :fill);
    }

    method field {
        @!fields[$!selected-field-ix];
    }

    method move-cursor(Int $d) {
        self.field.open-for-update = False;
        self.field.value-ix = Nil;

        my $old-ix = $!selected-field-ix;
        my $new-ix = $!selected-field-ix + $d;
        my $open-subrecord-ix = self.ix-of-field-with-open-subrecord;

        if $new-ix < 0 || $new-ix < $!top-field-ix
                       || $new-ix >= @!fields.elems
                       || $new-ix > $!number-of-display-lines + $!top-field-ix
                       || ($open-subrecord-ix.defined && $new-ix < $open-subrecord-ix)
                       || ($open-subrecord-ix.defined && $new-ix > $open-subrecord-ix + @!subrecords.first.elems) {
            print BEL;
        } else {
            $!selected-field-ix = $new-ix;
            self.draw-field($old-ix);
            self.draw-field;
            self.draw-help;
        }
    }

    method draw-field($ix = $!selected-field-ix) {
        my $line = $!first-display-line + $ix - $!top-field-ix;

        if $line < $!first-display-line || $line > self.last-display-line {
            return;
        }

        if (my $field = @!fields[$ix]) {
            print-at($line, 2, $field.render(:selected($ix == $!selected-field-ix),
                                             :$!subrecord-ix), :fill);

            if $field.parent-prop {
                self.draw-field(self.ix-of-field-with-open-subrecord);
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
                     ' ', :fill);
        } elsif $leading-count > 0 {
            print-at($!first-display-line - 1,
                     $!cursor-offset,
                     ansi('.', 'green') x $leading-count, :fill);
        }

        my $trailing-count = @!fields.elems - $!number-of-display-lines - $!top-field-ix - 1;

        if $trailing-count <= 0 {
            print-at($!number-of-display-lines + $!first-display-line + 1,
                     $!cursor-offset,
                     ' ', :fill);
        } elsif $trailing-count > 0 {
            print-at($!number-of-display-lines + $!first-display-line + 1,
                     $!cursor-offset,
                     ansi('.', 'green') x $trailing-count, :fill);
        }
    }

    method draw-header {
        print-at(1, 3, ansi(%!json<uri>, 'bold'));
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

        clear-screen();

        self.draw-header;
        self.draw-footer;

        my $k = '';

        self.draw-form();

        while $k ne 'q' {

	          $k = get-key-in;

	          given $k {
                when 's' {
                    for @!fields.grep(*.updated) -> $field {
                        %!json{$field.prop} = $field.value;
                    }

                    my %resp = from-json client.post(%!json<uri>, Empty, to-json %!json);

                    if %resp<error> {
                        my $msg = '';
                        for %resp<error>.kv -> $k, $v {
                            $msg ~= $k ~ ': ' ~ $v.join(',') ~ '  ';
                        }

                        self.message($msg);
                    } else {
                        self.message(%resp<status>);
                    }

                    if (my $open-subrecord-ix = self.ix-of-field-with-open-subrecord).defined {
                        $!selected-field-ix = $open-subrecord-ix;
                        $!subrecord-ix = Nil;
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
                when "\t" {
                    self.revert-value;
                    self.draw-field;
                }
                when 'd' {
                    if self.field.value ~~ Iterable {
                        if self.field.value-ix.defined {
                            self.field.value.splice(self.field.value-ix, 1);
                            self.set-value(self.field.value);
                            self.message("Item deleted from {self.field.prop}");
                            if self.field.value-ix >= self.field.value.elems {
                                self.field.value-ix = Nil;
                            }
                        } else {
                            self.set-value([]);
                            self.message("All {self.field.prop} deleted");
                        }
                    } else {
                        self.set-value('');
                    }
                    self.draw-field;
                }
                when 'a' {
                    my %search;
                    my $ix = 0;
                    my $q;
                    my $type = self.field.schema<items><properties><ref><type>;
                    if $type ~~ Array {
                        for |$type -> $t {
                            $t<type> ~~ s/^ 'JSONModel(:' (\w+) ') uri' $/$0/;
                        }
                        $type = $type.map(*.<type>).Array;
                    } else {
                        $type ~~ s/^ 'JSONModel(:' (\w+) ') uri' $/$0/;
                    }

                    self.draw-help(@add-value-help);

                    while (my $ak = get-key-in) {
                        given $ak {
                            when "\t" {
                                self.message("Exited add mode");
                                last;
                            }
                            when /\n/ {
                                self.field.value.push({ref => %search<results>[$ix]<uri>});
                                self.set-value(self.field.value);
                                self.draw-field;
                                self.message('Added ' ~ %search<results>[$ix]<uri> ~ ' to ' ~ self.field.prop);
                                last;
                            }
                            when ' ' {
                                $ix = ($ix + 1) % +%search<results>;
                                my $msg = %search<results>[$ix]<uri>;
                                if %search<results>[$ix]<title> {
                                    $msg ~= ' | ' ~ %search<results>[$ix]<title>;
                                }
                                self.message($msg);
                            }
                            default {
                                if $ak ~~ /\w/ {
                                    $q ~= $ak;
                                } elsif $ak.ord == 127 {
                                    $q.=substr(0, *-1) if $q;
                                }
                                if $q {
                                    %search = self.search-type($type, $q);
                                } else {
                                    self.message("Type to search");
                                }
                            }
                        }
                    }

                    self.draw-help;
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
                                my $coo = self.field.parent-prop ?? 5 !! 2;
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

                        if $prop<type> eq <array> {
                            if $prop<items><subtype> ~~ <ref> && !self.field.value.head<_resolved> {
                                my $resp = from-json client.get(%!json<uri>, ('resolve[]=' ~ self.field.prop,));
                                if $resp<error> {
                                    self.message($resp<error>);
                                } else {
                                    self.set-value($resp{self.field.prop});
                                }
                            }

                            self.load-subrecord-fields;

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
        } else {
            self.message("Found " ~ %resp<total_hits> ~ ' ' ~ $type ~ "s with '$q'");
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

   method label-for-json(%json) {
       %json{'display_string', 'title', 'name'}.grep(*.defined).head || '';
   }
}
