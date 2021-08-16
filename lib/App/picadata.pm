package App::picadata;
use v5.14.1;

our $VERSION = '1.29';

use Getopt::Long qw(GetOptionsFromArray :config bundling);
use Pod::Usage;
use PICA::Data qw(pica_parser pica_writer);
use PICA::Patch qw(pica_diff pica_patch);
use PICA::Schema qw(field_identifier);
use PICA::Schema::Builder;
use Getopt::Long qw(:config bundling);
use Pod::Usage;
use Scalar::Util qw(reftype);
use JSON::PP;
use List::Util qw(any all);
use Text::Abbrev;

my %TYPES = (
    bin    => 'Binary',
    dat    => 'Binary',
    binary => 'Binary',
    extpp  => 'Binary',
    ext    => 'Binary',
    plain  => 'Plain',
    pp     => 'Plain',
    plus   => 'Plus',
    norm   => 'Plus',
    normpp => 'Plus',
    xml    => 'XML',
    ppxml  => 'PPXML',
    json   => 'JSON',
    ndjson => 'JSON',
);

my %COLORS
    = (tag => 'blue', occurrence => 'blue', code => 'red', value => 'green');

sub new {
    my ($class, @argv) = @_;

    my $command = (!@argv && -t *STDIN) ? 'help' : '';    ## no critic

    my $number = 0;
    if (my ($i) = grep {$argv[$_] =~ /^-(\d+)$/} (0 .. @argv - 1)) {
        $number = -(splice @argv, $i, 1);
    }

    my $noAnnotate = grep {$_ eq '-A'} @argv;

    my @path;

    my $opt = {
        number  => \$number,
        help    => sub {$command = 'help'},
        version => sub {$command = 'version'},
        build   => sub {$command = 'build'},
        count   => sub {$command = 'count'},     # for backwards compatibility
        path    => \@path,
    };

    my %cmd = abbrev
        qw(convert count split fields subfields sf explain validate build diff patch help version);
    if ($cmd{$argv[0]}) {
        $command = $cmd{shift @argv};
        $command =~ s/^sf$/subfields/;
    }

    GetOptionsFromArray(
        \@argv,       $opt,           'from|f=s', 'to|t:s',
        'schema|s=s', 'annotate|A|a', 'abbrev|B', 'build|b',
        'unknown|u!', 'count|c',      'order|o',  'path|p=s',
        "number|n:i", 'color|C',      'mono|M',   'help|h|?',
        'version|V',
    ) or pod2usage(2);

    $opt->{number} = $number;
    $opt->{annotate} = 0 if $noAnnotate;
    $opt->{color}
        = !$opt->{mono} && ($opt->{color} || -t *STDOUT);    ## no critic

    delete $opt->{$_} for qw(count build help version);

    my $pattern = '[012.][0-9.][0-9.][A-Z@.](\$[^|]+|/[0-9.-]+)?';
    while (@argv && $argv[0] =~ /^$pattern(\s*\|\s*($pattern)?)*$/) {
        push @path, shift @argv;
    }

    if (@path) {
        @path = map {
            my $p = parse_path($_);
            $p || die "invalid PICA Path: $_\n";
        } grep {$_ ne ""} map {split /\s*\|\s*/, $_} @path;

        if ($command ne 'explain') {
            if (all {$_->subfields ne ""} @path) {
                $command = 'select' unless $command;
            }
            elsif (any {$_->subfields ne ""} @path) {
                $opt->{error}
                    = "PICA Path must either all select fields or all select subfields!";
            }
        }
    }

    $opt->{order} = 1 if $command =~ /(diff|patch|split)/;

    unless ($command) {
        if ($opt->{schema} && !$opt->{annotate}) {
            $command = 'validate';
        }
        elsif ($opt->{abbrev}) {
            $command = 'build';
        }
        else {
            $command = 'convert';
        }
    }

    if ($command =~ /validate|explain|fields|subfields/ && !$opt->{schema}) {
        if ($ENV{PICA_SCHEMA}) {
            $opt->{schema} = $ENV{PICA_SCHEMA};
        }
        elsif ($command =~ /validate|explain/) {
            $opt->{error}
                = "$command requires an Avram Schema (via option -s or environment variable PICA_SCHEMA)";
        }
    }

    $opt->{annotate} = 1 if $command eq 'diff';
    $opt->{annotate} = 0 if $command eq 'patch';

    if ($opt->{schema}) {
        $opt->{schema} = load_schema($opt->{schema});
        $opt->{schema}{ignore_unknown} = $opt->{unknown};
    }

    if ($command =~ qr{diff|patch}) {
        unshift @argv, '-' if @argv == 1;
        $opt->{error} = "$command requires two input files" if @argv != 2;

        if ($command eq 'diff') {

            # only Plain and JSON support annotations
            $opt->{to} = 'plain' unless $TYPES{lc $opt->{to}} eq 'JSON';
        }
    }

    $opt->{input} = @argv ? \@argv : ['-'];

    if ($opt->{from}) {
        $opt->{from} = $TYPES{lc $opt->{from}}
            or $opt->{error} = "unknown serialization type: " . $opt->{from};
    }

    # default output format
    unless ($opt->{to}) {
        if ($command =~ /(convert|split|diff|patch)/) {
            $opt->{to} = $opt->{from};
            $opt->{to} ||= $TYPES{lc $1}
                if $opt->{input}->[0] =~ /\.([a-z]+)$/;
            $opt->{to} ||= 'plain';
        }
        elsif ($command eq 'validate' && $opt->{annotate}) {
            $opt->{to} = 'plain';
        }
    }

    if ($opt->{to}) {
        $opt->{to} = $TYPES{lc $opt->{to}}
            or $opt->{error} = "unknown serialization type: " . $opt->{to};
    }

    $opt->{command} = $command;

    bless $opt, $class;
}

sub parser_from_input {
    my ($self, $in, $format) = @_;

    if ($in eq '-') {
        $in = *STDIN;
        binmode $in, ':encoding(UTF-8)';
    }
    else {
        die "File not found: $in\n" unless -e $in;
    }

    $format ||= $self->{from};
    $format ||= $TYPES{lc $1} if $in =~ /\.([a-z]+)$/;

    return pica_parser($format || 'plain', $in);
}

sub load_schema {
    my ($schema) = @_;
    my $json;
    if ($schema =~ qr{^https?://}) {
        require HTTP::Tiny;
        my $res = HTTP::Tiny->new->get($schema);
        die "HTTP request failed: $schema\n" unless $res->{success};
        $json = $res->{content};
    }
    else {
        open(my $fh, "<", $schema)
            or die "Failed to open schema file: $schema\n";
        $json = join "\n", <$fh>;
    }
    return PICA::Schema->new(JSON::PP->new->decode($json));
}

sub run {
    my ($self) = @_;
    my $command = $self->{command};
    my @pathes = @{$self->{path} || []};
    my $schema = $self->{schema};

    # commands that don't parse any input data
    if ($self->{error}) {
        pod2usage($self->{error});
    }
    elsif ($command eq 'help') {
        pod2usage(
            -verbose  => 99,
            -sections => "SYNOPSIS|COMMANDS|OPTIONS|DESCRIPTION|EXAMPLES"
        );
    }
    elsif ($command eq 'version') {
        say $PICA::Data::VERSION;
        exit;
    }
    elsif ($command eq 'explain') {
        $self->explain($schema, $_) for @pathes;
        unless (@pathes) {
            while (<STDIN>) {
                $self->explain($schema, $2)
                    if $_ =~ /^([^0-9a-z]\s+)?([^ ]+)/;
            }
        }
        exit;
    }

    # initialize writer and schema builder
    my $writer;
    if ($self->{to}) {
        $writer = pica_writer(
            $self->{to},
            color => ($self->{color} ? \%COLORS : undef),
            schema   => $schema,
            annotate => $self->{annotate},
        );
    }
    binmode *STDOUT, ':encoding(UTF-8)';

    my $builder
        = $command =~ /(build|fields|subfields|explain)/
        ? PICA::Schema::Builder->new($schema ? %$schema : ())
        : undef;

    # additional options
    my $number  = $self->{number};
    my $stats   = {records => 0, holdings => 0, items => 0, fields => 0};
    my $invalid = 0;

    my $process = sub {
        my $record = shift;

        if ($command eq 'select') {
            say $_ for map {@{$record->match($_, split => 1) // []}} @pathes;
        }

        $record = $record->sort if $self->{order};

        $record->{record} = $record->fields(@pathes) if @pathes;
        return if $record->empty;

        # TODO: also validate on other commands?
        if ($command eq 'validate') {
            my @errors = $schema->check(
                $record,
                ignore_unknown => !$self->{unknown},
                annotate       => $self->{annotate}
            );
            if (@errors) {
                unless ($self->{annotate}) {
                    say(defined $record->{_id} ? $record->{_id} . ": $_" : $_)
                        for @errors;
                }
                $invalid++;
            }
        }

        $writer->write($record) if $writer;
        $builder->add($record)  if $builder;

        if ($command eq 'count') {
            $stats->{holdings}
                += grep {@{$_->fields('1...')}} @{$record->holdings};
            $stats->{items} += grep {!$_->empty} @{$record->items};
            $stats->{fields} += @{$record->{record}};
        }
        $stats->{records}++;
    };

    if ($command eq 'diff') {
        my @parser = map {$self->parser_from_input($_)} @{$self->{input}};
        while (1) {
            my $a = $parser[0]->next;
            my $b = $parser[1]->next;
            if ($a or $b) {
                $writer->write(pica_diff($a || [], $b || []));
            }
            else {
                last;
            }
            last if $number && $number <= ++$stats->{record};
        }
    }
    elsif ($command eq 'patch') {
        my $parser = $self->parser_from_input($self->{input}[0]);

        # TODO: allow to read diff in PICA/JSON
        my $patches = $self->parser_from_input($self->{input}[1], 'plain');
        my $diff;
        while (my $record = $parser->next) {
            $diff = $patches->next || $diff;    # keep latest diff
            die "Missing patch to apply in $self->{input}[1]\n" unless $diff;

            my $changed = eval {pica_patch($record, $diff)};
            if (!$changed || $@) {
                warn $@;
            }
            else {
                $writer->write($changed || []);
            }

            last if $number && $number <= ++$stats->{record};
        }
    }
    else {
    RECORD: foreach my $in (@{$self->{input}}) {
            my $parser = $self->parser_from_input($in);
            while (my $next = $parser->next) {
                for ($command eq 'split' ? $next->split : $next) {
                    $process->($_);
                    last RECORD if $number and $stats->{records} >= $number;
                }
            }
        }
    }

    $writer->end() if $writer;

    if ($command eq 'count') {
        $stats->{invalid} = $invalid;
        say $stats->{$_} . " $_"
            for grep {$stats->{$_}} qw(records invalid holdings items fields);
    }
    elsif ($command =~ /(sub)?fields/) {
        my $fields = $builder->schema->{fields};
        for my $id (sort keys %$fields) {
            if ($command eq 'fields') {
                $self->document($id, $self->{abbrev} ? 0 : $fields->{$id});
            }
            else {
                my $sfs = $fields->{$id}->{subfields} || {};
                for (keys %$sfs) {
                    $self->document("$id\$$_",
                        $self->{abbrev} ? 0 : $sfs->{$_});
                }
            }
        }
    }
    elsif ($command eq 'build') {
        $schema = $builder->schema;
        print JSON::PP->new->indent->space_after->canonical->convert_blessed
            ->encode($self->{abbrev} ? $schema->abbreviated : $schema);
    }

    exit !!$invalid;
}

sub parse_path {
    eval {PICA::Path->new($_[0], position_as_occurrence => 1)};
}

sub explain {
    my $self   = shift;
    my $schema = shift;
    my $path   = parse_path($_[0]);

    if (!$path) {
        warn "invalid PICA Path: $_[0]\n";
        return;
    }
    elsif ($path->stringify =~ /[.]/) {
        warn "Fields with wildcards cannot be explained yet!\n";
        return;
    }

    my $tag = $path->fields;

    my ($firstocc) = grep {$_ > 0} split '-', $path->occurrences;
    my $id = field_identifier($schema, [$tag, $firstocc]);

    my $def = $schema->{fields}{$id};
    if (defined $path->subfields && $def) {
        my $sfdef = $def->{subfields} || {};
        for (split '', $path->subfields) {
            $self->document("$id\$$_", $sfdef->{$_}, 1);
        }
    }
    else {
        $self->document($id, $def, 1);
    }
}

sub document {
    my ($self, $id, $def, $warn) = @_;
    if ($def) {
        my $status = ' ';
        if ($def->{required}) {
            $status = $def->{repeatable} ? '+' : '.';
        }
        else {
            $status = $def->{repeatable} ? '*' : 'o';
        }
        my $doc = "$id\t$status\t" . $def->{label} // '';
        say $doc =~ s/[\s\r\n]+/ /mgr;
    }
    elsif (!$self->{unknown}) {
        if ($warn) {
            warn "$id\t?\n";
        }
        else {
            say $id;
        }
    }
}

=head1 NAME

App::picadata - Implementation of picadata command line application.

=head1 DESCRIPTION

This package implements the L<picadata> command line application.

=head1 COPYRIGHT AND LICENSE

Copyright 2020- Jakob Voss

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

1;
