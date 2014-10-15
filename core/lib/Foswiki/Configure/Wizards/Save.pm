package Foswiki::Configure::Wizards::Save;

=begin TML

---++ package Foswiki::Configure::Wizards::Save

Wizard to generate LocalSite.cfg file from current $Foswiki::cfg,
taking a backup as necessary.

=cut

use strict;
use warnings;

use Foswiki::Configure::Wizard ();
our @ISA = ('Foswiki::Configure::Wizard');

use Errno;
use Fcntl;
use File::Spec                   ();
use Foswiki::Configure::Load     ();
use Foswiki::Configure::LoadSpec ();
use Foswiki::Configure::FileUtil ();

use constant STD_HEADER => <<'HERE';
# Local site settings for Foswiki. This file is managed by the 'configure'
# CGI script, though you can also make (careful!) manual changes with a
# text editor.  See the Foswiki.spec file in this directory for documentation
# Extensions are documented in the Config.spec file in the Plugins/<extension>
# or Contrib/<extension> directories  (Do not remove the following blank line.)

HERE

# back up the current LSC content and return it
sub _backupCurrentContent {
    my ( $path, $reporter ) = @_;
    my $content;

    if ( open( F, '<', $path ) ) {
        local $/ = undef;
        $content = <F>;
        close(F);
    }
    else {
        return ($content) if ( $!{ENOENT} );    # Race: file disappeared
        die "Unable to read $path: $!\n";       # Serious error
    }

    unless ( defined $Foswiki::cfg{MaxLSCBackups}
        && $Foswiki::cfg{MaxLSCBackups} >= -1 )
    {
        $Foswiki::cfg{MaxLSCBackups} = 0;
        $reporter->CHANGED('{MaxLSCBackups}');
    }

    return ($content) unless ( $Foswiki::cfg{MaxLSCBackups} );

    # Save backup copy of current configuration (even if always_write)

    Fcntl->import(qw/:DEFAULT/);

    my ( $mode, $uid, $gid, $atime, $mtime ) = ( stat(_) )[ 2, 4, 5, 8, 9 ];

    # Find a reasonable starting point for the new backup's name

    my $n = 0;
    my ( $vol, $dir, $file ) = File::Spec->splitpath($path);
    $dir = File::Spec->catpath( $vol, $dir, 'x' );
    chop $dir;
    my @backups;
    if ( opendir( my $d, $dir ) ) {
        @backups =
          sort { $b <=> $a }
          map { /^$file\.(\d+)$/ ? ($1) : () } readdir($d);
        my $last = $backups[0];
        $n = $last if ( defined $last );
        $n++;
        closedir($d);
    }
    else {
        $n = 1;
        unshift @backups, $n++ while ( -e "$path.$n" );
    }

    # Find the actual filename and open for write

    my $open;
    my $um = umask(0);
    unshift @backups, $n++
      while (
        !(
            $open = sysopen( F, "$path.$n",
                O_WRONLY() | O_CREAT() | O_EXCL(), $mode & 07777
            )
        )
        && $!{EEXIST}
      );
    my $backup;
    if ($open) {
        $backup = "$path.$n";
        unshift @backups, $n;
        print F $content;
        close(F);
        utime $atime, $mtime, $backup;
        chown $uid, $gid, $backup;
    }
    else {
        die "Unable to open $path.$n for write: $!\n";
    }
    umask($um);

    return ( $content, $backup, @backups );
}

# For each key in the spec missing from the %cfg passed, add the
# default (unexpanded) from the spec to the %cfg, if it exists.
sub _addSpecDefaultsToCfg {
    my ( $spec, $cfg ) = @_;
    if ( $spec->{children} ) {
        foreach my $child ( @{ $spec->{children} } ) {
            _addSpecDefaultsToCfg( $child, $cfg );
        }
    }
    else {
        if ( exists( $spec->{default} )
            && eval("!exists(\$cfg->$spec->{keys})") )
        {
            # {default} stores a value string. Convert it to the
            # value suitable for storing in cfg
            my $value = $spec->decodeValue( $spec->{default} );
            if ( defined $value ) {
                eval("\$cfg->$spec->{keys}=\$value");
            }
            else {
                eval("undef \$cfg->$spec->{keys}");
            }
        }
    }
}

=begin TML

---++ WIZARD save
Params:
   * set - hash mapping keys to values

Returns a wizard report.

=cut

sub save {
    my ( $this, $reporter ) = @_;
    my $session = $Foswiki::Plugins::SESSION;

    # Sort keys so it's possible to diff LSC files.
    local $Data::Dumper::Sortkeys = 1;

    my %changeLog;

    my $root = Foswiki::Configure::Root->new();
    Foswiki::Configure::LoadSpec::readSpec($root);

    my $lsc = Foswiki::Configure::FileUtil::lscFileName();

    # Pick up any missing config options from .spec
    # SMELL: this *should* be a NOP, if the wizards did their job correctly,
    # though if an extension was installed from the shell when we weren't
    # looking it might be required.
    _addSpecDefaultsToCfg( $root, \%Foswiki::cfg );

    my ( $old_content, $backup, @backups ) =
      _backupCurrentContent( $lsc, $reporter );

    my %orig_content;    # used so diff detects remapping of keys

    if ( defined $old_content && $old_content =~ /^(.*)$/s ) {

        # Eval the old LSC and extract the content (assuming we can)
        local %Foswiki::cfg;
        eval $1;
        if ($@) {
            print STDERR "Error reading existing $lsc: $@";

            # Continue, but will be unable to detect changes
        }
        else {
            %orig_content = %Foswiki::cfg;

            # Clean out deprecated settings, so they don't occlude the
            # replacements
            foreach my $key ( keys %Foswiki::Configure::Load::remap ) {
                $old_content =~ s/\$Foswiki::cfg$key\s*=.*?;\s*//sg;
            }
        }
    }

    unless ( defined $old_content ) {

        # Construct a new LocalSite.cfg from the spec
        local %Foswiki::cfg = ();

        #---++ StaticMethod readConfig([$noexpand][,$nospec][,$config_spec])
        Foswiki::Configure::Load::readConfig( 1, 0, 1 );
        delete $Foswiki::cfg{ConfigurationFinished};
        $old_content =
          STD_HEADER
          . join( '', _spec_dump( $root, \%Foswiki::cfg, '' ) ) . "1;\n";
    }

    my %save;
    foreach my $key ( @{ $Foswiki::cfg{BOOTSTRAP} } ) {
        eval(" (\$save$key)  = \$Foswiki::cfg$key =~ /^(.*)\$/ ");
        delete $Foswiki::cfg{BOOTSTRAP};
    }

    # Clear out the configuration and re-initialize it either
    # with or without the .spec expansion.
    if ( $Foswiki::cfg{isBOOTSTRAPPING} ) {
        %Foswiki::cfg = ();

        # Read without expansions but with the .spec
        Foswiki::Configure::Load::readConfig( 1, 0, 1 );
    }
    else {
        %Foswiki::cfg = ();

        # Read without expansions and without the .spec
        Foswiki::Configure::Load::readConfig( 1, 1 );
    }

    # apply bootstrapped settings
    # print STDERR join( '', _spec_dump( $root, \%save, '' ) );
    eval( join( '', _spec_dump( $root, \%save, '' ) ) );
    die "Internal error: $@" if ($@);

    # Get changes from 'set' *without* expanding values
    if ( $this->param('set') ) {
        while ( my ( $k, $v ) = each %{ $this->param('set') } ) {
            if ( defined $v && $v ne '' ) {
                my $spec  = $root->getValueObject($k);
                my $value = $v;
                if ($spec) {
                    $value = $spec->decodeValue($value);
                }
                if ( defined $value ) {
                    eval "\$Foswiki::cfg$k=\$value";
                }
                else {
                    eval "undef \$Foswiki::cfg$k";
                }
            }
            else {
                eval "undef \$Foswiki::cfg$k";
            }
        }
    }

    delete $Foswiki::cfg{ConfigurationFinished};
    my $new_content =
      STD_HEADER . join( '', _spec_dump( $root, \%Foswiki::cfg, '' ) ) . "1;\n";

    if ( $new_content ne $old_content ) {
        my $um = umask(007);   # Contains passwords, no world access to new file
        open( F, '>', $lsc )
          || die "Could not open $lsc for write: $!\n";
        print F $new_content;
        close(F) or die "Close failed for $lsc: $!\n";
        umask($um);
        if ( $backup && ( my $max = $Foswiki::cfg{MaxLSCBackups} ) >= 0 ) {
            while ( @backups > $max ) {
                my $n = pop @backups;
                unlink "$lsc.$n";
            }
            $reporter->NOTE("Previous configuration saved in $backup");
        }
        $reporter->NOTE("New configuration saved in $lsc");

        _compareConfigs( $root, \%orig_content, \%Foswiki::cfg, $reporter )
          if (%orig_content);
    }
    else {
        unlink $backup if ($backup);
        $reporter->NOTE("No change made to $lsc");
    }
    return undef;    # return the report
}

sub _compareConfigs {

    my ( $spec, $oldcfg, $newcfg, $reporter ) = @_;

    $reporter->NOTE('| *Key* | *Old* | *New* |');
    local $Data::Dumper::Terse    = 1;
    local $Data::Dumper::Indent   = 0;
    local $Data::Dumper::SortKeys = 1;

    _same( $spec, $oldcfg, $newcfg, '', $reporter );
}

sub _dump {
    my $val = shift;
    local $Data::Dumper::Indent = 0;
    return Data::Dumper->Dump( [$val] );
}

sub _same {
    my ( $spec, $o, $n, $keypath, $reporter ) = @_;
    my ( $old, $new );

    return 1 unless ( defined $o || defined $n );

    if ( ref($o) ne ref($n) ) {
        $old = _dump($o);
        $new = _dump($n);
        $reporter->NOTE("| $keypath | $old | $new |") if $reporter;
        return 0;
    }

    # We know they are the same type
    if ( ref($o) eq 'HASH' ) {
        my %keys = map { $_ => 1 } ( keys %$o, keys %$n );
        my $ok = 1;
        foreach my $k ( sort keys %keys ) {
            unless (
                _same(
                    $spec,
                    $o->{$k},
                    $n->{$k},
                    $keypath . '{'
                      . Foswiki::Configure::LoadSpec::protectKey($k) . '}',
                    $reporter
                )
              )
            {
                $ok = 0;
            }
        }
        return $ok;
    }

    if ( ref($o) eq 'ARRAY' ) {
        if ( scalar(@$o) != scalar(@$n) ) {
            $old = '[' . scalar(@$o) . ']';
            $new = '[' . scalar(@$n) . ']';
            $reporter->NOTE("| $keypath | $old | $new |") if $reporter;
            return 0;
        }
        else {
            for ( my $i = 0 ; $i < scalar(@$o) ; $i++ ) {
                unless ( _same( $spec, $o->[$i], $n->[$i], "$keypath\[$i\]" ) )
                {
                    if ($reporter) {
                        $old = _dump($o);
                        $new = _dump($n);
                        $reporter->NOTE("| $keypath | $old | $new |");
                    }
                    return 0;
                }
            }
        }
    }
    elsif (( !defined $o && defined $n )
        || ( defined $o && !defined $n )
        || $o ne $n )
    {
        if ( my $vs = $spec->getValueObject($keypath) ) {
            if ( $vs->{typename} eq 'PASSWORD' ) {
                $reporter->NOTE("| $keypath | _[redacted]_ | _[redacted]_ |")
                  if $reporter;
                return 0;
            }
        }

        $old = _dump($o);
        $new = _dump($n);
        $reporter->NOTE("| $keypath | $old | $new |") if $reporter;
        return 0;
    }

    return 1;
}

sub _spec_dump {
    my ( $spec, $datum, $keys ) = @_;

    my @dump;
    if ( my $vs = $spec->getValueObject($keys) ) {
        my $d;
        if ( $vs->{typename} eq 'REGEX' ) {
            $datum = "$datum";
        }
        if ( $vs->{typename} eq 'BOOLEAN' ) {
            $d = ( $datum ? 1 : 0 );
        }
        elsif ( $vs->{typename} eq 'NUMBER' ) {
            $d = $datum;
        }

        # SMELL: Perl Datatype comes in from JSON as a quoted string,
        # but might be stored as a HASH or ARRAY,
        elsif ( $vs->{typename} eq 'PERL' && !ref($datum) ) {
            print STDERR "Setting $keys to ($datum)\n";
            $d = "$datum";
        }
        else {
            $d = Data::Dumper->Dump( [$datum] );
            $d =~ s/^\$VAR1\s*=\s*//s;
            $d =~ s/;\s*$//s;
        }
        push( @dump, "\$Foswiki::cfg$keys = $d;\n" );
    }
    elsif ( ref($datum) eq 'HASH' ) {
        foreach my $k ( sort keys %$datum ) {
            my $v  = $datum->{$k};
            my $sk = Foswiki::Configure::LoadSpec::protectKeys("{$k}");
            push( @dump, _spec_dump( $spec, $v, "${keys}$sk" ) );
        }
    }
    else {
        my $d = Data::Dumper->Dump( [$datum] );
        my $sk = Foswiki::Configure::LoadSpec::protectKeys($keys);
        $d =~ s/^\$VAR1/\$Foswiki::cfg$sk/;
        push( @dump, "# Not found in .spec\n" );
        push( @dump, $d );
    }

    return @dump;
}

1;
