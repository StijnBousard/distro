# See bottom of file for license and copyright information
package Foswiki;

use strict;
use warnings;

use File::Spec;
use Data::Dumper;
use Foswiki::Func;
use Config;
use Storable;

sub PENDINGREGISTRATIONS {
    my ( $this, $params ) = @_;

    Foswiki::Func::loadTemplate('PendingRegistrations');

    my $report;

    if ( ( !defined $params->{_DEFAULT} )
        || lc( $params->{_DEFAULT} ) eq 'approval' )
    {
        $report .= $this->_checkPendingRegistrations('Approval');
    }

    if ( ( !defined $params->{_DEFAULT} )
        || lc( $params->{_DEFAULT} ) eq 'verification' )
    {
        $report .= $this->_checkPendingRegistrations('Verification');
    }

    return $report;
}

sub _checkAccess {
    my $this = shift;

    return (
        $this->{users}->isAdmin( $this->{user} )
          || ( $Foswiki::cfg{Register}{Approvers}
            && $Foswiki::cfg{Register}{Approvers} =~ m/\b\Q$this->{user}\E\b/ )
    );
}

# Check pending registrations for duplicate email, or expiration
sub _checkPendingRegistrations {
    my $this   = shift;
    my $check  = shift;
    my $report = '';

    unless ( $this->_checkAccess() ) {
        return Foswiki::Func::expandTemplate('accessdenied');
    }

    my $dir = "$Foswiki::cfg{WorkingDir}/registration_approvals/";

    if ( opendir( my $d, "$dir" ) ) {
        foreach my $f ( grep { /^.*\.[0-9]{1,8}$/ } readdir $d ) {
            my $regFile = Foswiki::Sandbox::untaintUnchecked("$dir$f");

            my $data = retrieve($regFile);
            next unless defined $data;
            next unless $data->{ $check . 'Code' };
            $report .= _reportPending( $data, $check );
        }
        closedir($d);
    }
    my $header = '';
    if ($report) {
        $header = Foswiki::Func::expandTemplate( $check . 'Header' );
    }
    return $header . $report;
}

sub _reportPending {
    my $hashref = shift;
    my $check   = shift;

    my $tmpl = Foswiki::Func::expandTemplate($check);

    my $report = '';
    foreach my $field ( sort { lc($a) cmp lc($b) } keys %$hashref ) {
        next if $field eq 'form';
        next if $field eq 'Confirm';
        next if $field eq 'Password';
        $tmpl =~ s/\$$field/$hashref->{$field}/g;

        #$report .=  "$field: $hashref->{$field}\n";
    }
    print STDERR Data::Dumper::Dumper( \$hashref );
    return "$tmpl";
}

1;

__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2014-2016 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
