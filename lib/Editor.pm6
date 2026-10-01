use Functions;

use Terminal::LineEditor;
use Terminal::LineEditor::RawTerminalInput;
use JSON::Tiny;

class FormField {
    has $.prop;
    has $.value is rw;
    has $.original-value is rw;
    has Bool $.open-for-update is rw = False;
    has Int $.value-ix is rw;
    has Str $.translation is rw;

    submethod TWEAK {
        $!original-value = $!value;
    }

    my $.prop-width;

    method next-value {
        if $!value-ix.defined {
            $!value-ix = ($!value-ix + 1) % $!value.elems;
            if $!value-ix == 0 { $!value-ix = Nil; }
        } else {
            $!value-ix = 0;
        }
    }

    method updated {
        if $!value ~~ Hash {
            $!value !eqv $!original-value;
        } elsif $!value ~~ Iterable {
            # $!value might have been populated with _resolveds
            $!value.map({ %(.grep({ .key ne <_resolved> }))}).Array !eqv $!original-value;
        } else {
            $!value !eqv $!original-value;
        }
    }

    method render(:$selected) {
        my $value-style = '';
        if $!open-for-update {
            $value-style = 'green';
        } elsif self.updated {
            $value-style = 'cyan';
        }

        my $val = $!value;
        if !$val.defined || $val ~~ '' {
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
                        my $label = $item<_resolved>{'display_string', 'title', 'name'}.grep(*.defined).head;
                        $val = ansi($item<ref> ~ ' | ' ~ $label, "bold $value-style");
                    } else {
                        $val = ansi($item<ref>, "bold $value-style");
                    }
                } else {
                    $val = ansi($item.gist, "bold $value-style");;
                }
            } else {
                $val = "{ansi($val.elems.Str, "bold $value-style")} $!prop";
            }
        } else {
            $val.=trans("\n" => ' ');
            my $max_val_length = term_cols() - self.prop-width - 20;

            if $!translation {
                $val ~= " | $!translation";
            }

            if $val.chars > $max_val_length {
                $val = $val.substr(0,$max_val_length) ~ ' ...';
            }
            $val = ansi($val, "bold $value-style");
        }

        my $cursor = $selected ?? ansi('>>', 'bold green') !! '::';

        sprintf("%{self.prop-width}s $cursor %s\n", $!prop, $val);
    }
}

class Editor {
    has %.json;
    has FormField @.fields;
    has $.schema;
    has $.selected-field-ix = 0;
    has $.cursor-offset;
    has $.top-field-ix = 0;
    has $.max-top-field-ix;
    has $.number-of-display-lines = term_lines() - 6;
    has $.first-display-line = 3;
    has @.skip_props = <uri created_by last_modified_by jsonmodel_type user_mtime system_mtime create_time lock_version>;

    my @default-help =
        'Q' => 'Quit',
        'S' => 'Save',
        "\c[UPWARDS ARROW] \c[DOWNWARDS ARROW]" => 'Cursor up/down',
        "\c[LEFTWARDS ARROW] \c[RIGHTWARDS ARROW]" => 'Scroll up/down',
        '1 2 ..' => 'Page',
        'J' => 'JSON',
        'SPACE' => 'Edit',
        'TAB' => 'Revert',
        'D' => 'Delete';

    my @array-help =
        'A' => 'Add';

    submethod TWEAK {
        $!schema = schemas(:name(%!json<jsonmodel_type>));

        return unless $!schema;

        my @props = |$!schema<property_list>;
        my $longest = @props>>.chars.max;
        my $max_val_length = term_cols() - $longest - 20;
        $!cursor-offset = $longest + 3;
        FormField.prop-width = $longest;

        for @props -> $prop {
            my $schema_prop = $!schema<properties>{$prop};
            next if $schema_prop<readonly>;
            next if @!skip_props.grep($prop);

            @!fields.push(FormField.new(:$prop, :value(%!json{$prop})));
        }

        $!max-top-field-ix = [0, @!fields.elems - $!number-of-display-lines].max;
    }

    method message($s) {
        print-at(term_lines() - 1, 3, ansi($s, 'yellow'), :fill);
    }

    method field {
        @!fields[$!selected-field-ix];
    }

    method move-cursor(Int $d) {
        self.field.open-for-update = False;
        self.field.value-ix = Nil;

        my $old-ix = $!selected-field-ix;
        my $new-ix = $!selected-field-ix + $d;

        if $new-ix < 0 || $new-ix < $!top-field-ix
                       || $new-ix >= @!fields.elems
                       || $new-ix > $!number-of-display-lines + $!top-field-ix {
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
        if @!fields[$ix] && $line >= 0 && $line <= $!number-of-display-lines + $!first-display-line {
            print-at($line, 2, @!fields[$ix].render(:selected($ix == $!selected-field-ix)), :fill);
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

    method draw-help(@items?, :$add) {
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
                        $field.original-value = $field.value;
                        %!json{$field.prop} = $field.value;
                    }

                    my %resp = from-json client.post(%!json<uri>, Empty, to-json %!json);

                    self.draw-form;
                    if %resp<error> {
                        my $msg = '';
                        for %resp<error>.kv -> $k, $v {
                            $msg ~= $k ~ ': ' ~ $v.join(',') ~ '  ';
                        }

                        self.message($msg);
                    } else {
                        %!json<lock_version> = %resp<lock_version>;
                        self.message(%resp<status>);
                    }

                }
                when "\t" {
                    self.field.open-for-update = False;
                    self.field.value = self.field.original-value;
                    self.draw-field;
                }
                when 'd' {
                    if self.field.value ~~ Iterable {
                        if self.field.value-ix.defined {
                            self.field.value.splice(self.field.value-ix, 1);
                            self.message("Item deleted from {self.field.prop}");
                            if self.field.value-ix >= self.field.value.elems {
                                self.field.value-ix = Nil;
                            }
                        } else {
                            self.field.value = [];
                            self.message("All {self.field.prop} deleted");
                        }
                    } else {
                        self.field.value = '';
                    }
                    self.draw-field;
                }
                when ' ' {
                    my $prop = $!schema<properties>{self.field.prop};

                    if self.field.open-for-update {
                        if $prop<type> eq 'boolean' {
                            self.field.value = !self.field.value;
                            self.draw-field;
                        } elsif $prop<enum> {
                            my $next-ix = $prop<enum>.first(self.field.value, :k) + 1;
                            $next-ix %= $prop<enum>.elems;
                            self.field.value = $prop<enum>[$next-ix];
                            self.draw-field;
                        } elsif $prop<dynamic_enum> {
                            my $enum = enum-by-name($prop<dynamic_enum>);
                            my @values = |$enum<values>;
                            my $next-ix = @values.first(self.field.value, :k) + 1;
                            $next-ix %= @values.elems;
                            self.field.value = @values[$next-ix];
                            self.field.translation = $enum<value_translations>{self.field.value};
                            self.draw-field;
                        } elsif $prop<type> eq 'string' {
                            my $val = self.field.value // '';
                            if $val.chars > term_cols() - $!cursor-offset - 20 || $val ~~ /\n/ {
                                save_tmp(self.field.value);
                                if edit(tmp_file) {
                                    self.field.value = slurp(tmp_file).chomp;
                                    self.message('Edits applied');
                                } else {
                                    self.message('No edits');
                                }
                                run <tput civis>;
                            } else {
                                cursor($!cursor-offset + 2, $!first-display-line + $!selected-field-ix - $!top-field-ix);
                                run <tput cvvis>;
                                my $cli = Terminal::LineEditor::CLIInput.new;

                                # these don't work :( i see the value appear but gets blatted immediately
                                # $cli.replace-input-field(:50display-width, :0field-start, :content($field.value));
                                # $cli.do-edit('insert-string', $field.value);

                                # so use history instead - sigh
                                $cli.add-history(self.field.value);

                                self.field.value = $cli.prompt;
                                run <tput civis>;
                                self.draw-field;
                            }
                        } elsif $prop<type> eq 'array' {
                            if $prop<items><subtype> ~~ <ref> {
                                self.field.next-value;
                                self.draw-field;
                                # while (my $ak = get-key-in) ne 'q' {
                                #     given $ak {
                                #         when ' ' {
                                #             $field.next-value;
                                #             self.draw-field;
                                #         }
                                #     }
                                # }
                            }
                        }
                    } else {
                        self.field.open-for-update = True;

                        if $prop<type> eq <array> {
                            if $prop<items><subtype> ~~ <ref> && !self.field.value.head<_resolved> {
                                my $resp = from-json client.get(%!json<uri>, ('resolve[]=' ~ self.field.prop,));
                                if $resp<error> {
                                    self.message($resp<error>);
                                } else {
                                    self.field.value = $resp{self.field.prop};
                                }
                            }
                            self.draw-help(@array-help, :add);
                        }

                        self.draw-field;
                    }
                }
                when 'j' {
                    page(pretty to-json %!json{self.field.prop});
                }
                when 'J' {
                    page(pretty to-json %!json);
                }
                when /\d/ {
                    my $ix = $!number-of-display-lines * ($k - 1);
                    if $ix > +@!fields {
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
                    if $!top-field-ix + 1 >= $!max-top-field-ix {
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

}
