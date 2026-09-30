use Functions;

class FormField {
    has $.prop;
    has $.value is rw;
    has $.original-value;
    has Bool $.open-for-update is rw = False;

    submethod TWEAK {
        $!original-value = $!value;
    }

    my $.prop-width;

    method updated {
        $!value !eqv $!original-value;
    }

    method render(:$selected) {
        my $value-style = '';
        if $!open-for-update {
            $value-style = 'green';
        } elsif self.updated {
            $value-style = 'cyan';
        }

        my $val = $!value;
        if !$val.defined {
            $val //= ansi('--', $value-style);
        } elsif $val ~~ Iterable {
            $val = "{ansi($val.elems.Str, "bold $value-style")} $!prop";
        } else {
            $val.=trans("\n" => ' ');
            my $max_val_length = term_cols() - self.prop-width - 20;
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

    method move-cursor(Int $d) {
        my $old-field = @!fields[$!selected-field-ix];
        $old-field.open-for-update = False;
        my $old-ix = $!selected-field-ix;
        my $new-ix = $!selected-field-ix + $d;

        if $new-ix < 0 || $new-ix >= @!fields.elems {
            print BEL;
        } else {
            $!selected-field-ix = $new-ix;
            self.draw-field($old-ix);
            self.draw-field;
        }
    }

    method draw-field($ix = $!selected-field-ix) {
        my $line = $!first-display-line + $ix - $!top-field-ix;
        if @!fields[$ix] && $line >= 0 && $line <= $!number-of-display-lines + $!first-display-line {
            print-at($line, 2, @!fields[$ix].render(:selected($ix == $!selected-field-ix)), :fill);
        }
    }

    method draw-form {
        for 0 .. $!number-of-display-lines -> $i {
            my $ix = $i + $!top-field-ix;
            last unless @!fields[$ix];
            self.draw-field($ix);
        }

        print-at($!number-of-display-lines + $!first-display-line + 2, 2, "{@!fields.elems - $!number-of-display-lines - $!top-field-ix - 1} more fields", :fill);
    }

    method edit-screen {
        ENTER {
            run <tput civis>;
        }
        LEAVE {
            cursor(0, term_lines());
            run <tput cvvis>;
        }

        clear-screen();
        print-at(1, 3, ansi(%!json<uri>, 'bold'));

        my $k = '';

        self.draw-form();

        while $k ne 'q' {

	          $k = get-key-in;

	          given $k {
                when "\t" {
                    my $field = @!fields[$!selected-field-ix];
                    $field.open-for-update = False;
                    $field.value = $field.original-value;
                    self.draw-field;
                }
                when ' ' {
                    my $field = @!fields[$!selected-field-ix];
                    if $field.open-for-update {
                        my $prop = $!schema<properties>{$field.prop};

                        if $prop<type> eq 'boolean' {
                            $field.value = !$field.value;
                            self.draw-field;
                        } elsif $prop<enum> {
                            my $next-ix = $prop<enum>.first($field.value, :k) + 1;
                            $next-ix %= $prop<enum>.elems;
                            $field.value = $prop<enum>[$next-ix];
                            self.draw-field;
                        } elsif $prop<dynamic_enum> {
                            my $enum = enum-by-name($prop<dynamic_enum>);
                            my @values = |$enum<values>;
                            my $next-ix = @values.first($field.value, :k) + 1;
                            $next-ix %= @values.elems;
                            $field.value = @values[$next-ix];
                            self.draw-field;
                        } elsif $prop<type> eq 'string' {
                            # hmm
                        }

                    } else {
                        $field.open-for-update = True;
                        self.draw-field;
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
                    } else {
                        $!top-field-ix++;
                        self.draw-form();
                    }
		            }
		            when LEFT_ARROW {
                    if $!top-field-ix < 1 {
                        print BEL;
                    } else {
                        $!top-field-ix--;
                        self.draw-form();
                    }
		            }
	          }

        }


        "Closed form for {%!json<uri>}";
    }

}
