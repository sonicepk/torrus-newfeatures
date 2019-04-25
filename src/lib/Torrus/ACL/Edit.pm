#  Copyright (C) 2002  Stanislav Sinyagin
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.

# Stanislav Sinyagin <ssinyagin@k-open.com>


package Torrus::ACL::Edit;
use strict;
use warnings;

use base 'Torrus::ACL';

use Torrus::ACL;
use Torrus::Log;


sub new
{
    my $proto = shift;
    my %options = @_;
    my $class = ref($proto) || $proto;
    my $self  = $class->SUPER::new( %options );
    bless $self, $class;
    return $self;
}


sub _users_list_read
{
    my $self = shift;
    my $key = shift;
    my $val = shift;

    my $list = $self->_users_get($key);
    $list = '' unless defined($list);
    my $hash = {};
    foreach my $member (split(',', $list))
    {
        $hash->{$member} = 1;
    }
    return $hash;
}


sub _users_list_add
{
    my $self = shift;
    my $key = shift;
    my $val = shift;

    my $hash = $self->_users_list_read($key);
    $hash->{$val} = 1;
    $self->_users_set($key, join(',', sort keys %{$hash}));
    return;
}

sub _users_list_del
{
    my $self = shift;
    my $key = shift;
    my $val = shift;

    my $hash = $self->_users_list_read($key);
    delete $hash->{$val};
    $self->_users_set($key, join(',', sort keys %{$hash}));
    return;
}


sub _users_set
{
    my $self = shift;
    my $key = shift;
    my $val = shift;

    return $self->{'redis'}->hset($self->{'users_hname'}, $key, $val);
}

sub _users_del
{
    my $self = shift;
    my $key = shift;

    return $self->{'redis'}->hdel($self->{'users_hname'}, $key);
}


sub _users_list_search
{
    my $self = shift;
    my $key = shift;
    my $val = shift;
    
    my $hash = $self->_users_list_read($key);
    return defined($hash->{$val});
}


sub addGroups
{
    my $self = shift;
    my @groups = shift;

    my $ok = 1;
    foreach my $group ( @groups )
    {
        if( length( $group ) == 0 or $group =~ /\W/ )
        {
            Error('Invalid group name: ' . $group);
            $ok = 0;
        }
        elsif( $self->groupExists( $group ) )
        {
            Error('Cannot add group ' . $group . ': the group already exists');
            $ok = 0;
        }
        else
        {
            $self->_users_list_add('G:', $group);
            $self->setGroupModified( $group );
            Info('Group added: ' . $group);
        }
    }
    return $ok;
}


sub deleteGroups
{
    my $self = shift;
    my @groups = shift;

    my $ok = 1;
    foreach my $group ( @groups )
    {
        if( $self->groupExists( $group ) )
        {
            my $members = $self->listGroupMembers( $group );
            foreach my $uid ( @{$members} )
            {
                $self->_users_list_del( 'gm:' . $uid, $group );
            }
            $self->_users_list_del( 'G:', $group );

            my $all = $self->{'redis'}->hgetall($self->{'acl_hname'});
            while( scalar(@{$all}) > 0 )
            {
                my $key = shift @{$all};
                my $val = shift @{$all};

                my( $dbgroup, $object, $privilege ) = split( ':', $key );
                if( $dbgroup eq $group )
                {
                    $self->{'redis'}->hdel($key);
                }
            }
            Info('Group deleted: ' . $group);
        }
        else
        {
            Error('Cannot delete group ' . $group .
                  ': the group does not exist');
            $ok = 0;
        }
    }
    return $ok;
}

sub groupExists
{
    my $self = shift;
    my $group = shift;

    return $self->_users_list_search( 'G:', $group );
}


sub listGroups
{
    my $self = shift;

    my $hash = $self->_users_list_read('G:');
    return sort keys %{$hash};
}


sub listGroupMembers
{
    my $self = shift;
    my $group = shift;

    my $members = [];

    my $all = $self->{'redis'}->hgetall($self->{'users_hname'});
    while( scalar(@{$all}) > 0 )
    {
        my $key = shift @{$all};
        my $val = shift @{$all};

        my( $selector, $uid ) = split(':', $key);
        if( $selector eq 'gm' )
        {
            if( defined($val) and length($val) > 0 and
                grep {$group eq $_} split(',', $val) )
            {
                push( @{$members}, $uid );
            }
        }
    }
    return [sort @{$members}];
}


sub addUserToGroups
{
    my $self = shift;
    my $uid = shift;
    my @groups = @_;

    my $ok = 1;
    if( $self->userExists( $uid ) )
    {
        foreach my $group ( @groups )
        {
            if( $self->groupExists( $group ) )
            {
                if( not grep {$group eq $_} $self->memberOf( $uid ) )
                {
                    $self->_users_list_add( 'gm:' . $uid, $group );
                    $self->setGroupModified( $group );
                    Info('Added ' . $uid . ' to group ' . $group);
                }
                else
                {
                    Error('Cannot add ' . $uid . ' to group ' . $group .
                          ': user is already a member of this group');
                    $ok = 0;
                }
            }
            else
            {
                Error('Cannot add ' . $uid . ' to group ' . $group .
                      ': group does not exist');
                $ok = 0;
            }
        }
    }
    else
    {
        Error('Cannot add user ' . $uid .
              'to groups: user does not exist');
        $ok = 0;
    }
    return $ok;
}


sub delUserFromGroups
{
    my $self = shift;
    my $uid = shift;
    my @groups = shift;

    my $ok = 1;
    if( $self->userExists( $uid ) )
    {
        foreach my $group ( @groups )
        {
            if( $self->groupExists( $group ) )
            {
                if( grep {$group eq $_} $self->memberOf( $uid ) )
                {
                    $self->_users_list_del( 'gm:' . $uid, $group );
                    $self->setGroupModified( $group );
                    Info('Deleted ' . $uid . ' from group ' . $group);
                }
                else
                {
                    Error('Cannot delete ' . $uid . ' from group ' . $group .
                          ': user is not a member of this group');
                    $ok = 0;
                }
            }
            else
            {
                Error('Cannot detete ' . $uid . ' from group ' . $group .
                      ': group does not exist');
                $ok = 0;
            }
        }
    }
    else
    {
        Error('Cannot delete user ' . $uid .
              'from groups: user does not exist');
        $ok = 0;
    }
    return $ok;
}


sub addUser
{
    my $self = shift;
    my $uid = shift;
    my $attrValues = shift;

    my $ok = 1;
    if( length( $uid ) == 0 or $uid =~ /\W/ )
    {
        Error('Invalid user ID: ' . $uid);
        $ok = 0;
    }
    elsif( $self->userExists( $uid ) )
    {
        Error('Cannot add user ' . $uid . ': the user already exists');
        $ok = 0;
    }
    else
    {
        $self->setUserAttribute( $uid, 'uid', $uid );
        if( defined( $attrValues ) )
        {
            $self->setUserAttributes( $uid, $attrValues );
        }
        Info('User added: ' . $uid);
    }
    return $ok;
}


sub userExists
{
    my $self = shift;
    my $uid = shift;

    my $dbuid = $self->userAttribute( $uid, 'uid' );
    return( defined( $dbuid ) and ( $dbuid eq $uid ) );
}


sub listUsers
{
    my $self = shift;

    my @ret;

    my $all = $self->{'redis'}->hgetall($self->{'users_hname'});
    while( scalar(@{$all}) > 0 )
    {
        my $key = shift @{$all};
        my $val = shift @{$all};
        
        my( $selector, $uid, $attr ) = split(':', $key);
        if( $selector eq 'ua' and $attr eq 'uid' )
        {
            push( @ret, $uid );
        }
    }
    return sort @ret;
}


sub setUserAttribute
{
    my $self = shift;
    my $uid = shift;
    my $attr = shift;
    my $val = shift;

    my $ok = 1;
    if( length( $attr ) == 0 or $attr =~ /\W/ )
    {
        Error('Invalid attribute name: ' . $attr);
        $ok = 0;
    }
    else
    {
        $self->_users_set( 'ua:' . $uid . ':' . $attr, $val );
        $self->_users_list_add( 'uA:' . $uid, $attr );
        if( $attr ne 'modified' )
        {
            $self->setUserModified( $uid );
        }
        Debug('Set ' . $attr . ' for ' . $uid . ': ' . $val);
    }
    return $ok;
}


sub delUserAttribute
{
    my $self = shift;
    my $uid = shift;
    my @attrs = @_;

    foreach my $attr ( @attrs )
    {
        $self->_users_del( 'ua:' . $uid . ':' . $attr );
        $self->_users_list_del( 'uA:' . $uid, $attr );
        $self->setUserModified( $uid );
        Debug('Deleted ' . $attr . ' from ' . $uid);
    }
    return;
}


sub setUserAttributes
{
    my $self = shift;
    my $uid = shift;
    my $attrValues = shift;

    my $ok = 1;
    
    foreach my $attr ( keys %{$attrValues} )
    {
        $ok = $self->setUserAttribute( $uid, $attr, $attrValues->{$attr} )
            ? $ok:0;
    }
    
    return $ok;
}


sub setUserModified
{
    my $self = shift;
    my $uid = shift;

    $self->setUserAttribute( $uid, 'modified', scalar( localtime( time() ) ) );
    return;
}


sub listUserAttributes
{
    my $self = shift;
    my $uid = shift;

    my $hash = $self->_users_list_read( 'uA:' . $uid );
    return sort keys %{$hash};
}


sub setPassword
{
    my $self = shift;
    my $uid = shift;
    my $password = shift;

    my $ok = 1;
    if( $self->userExists( $uid ) )
    {
        if( length( $password ) < $Torrus::ACL::minPasswordLength )
        {
            Error('Password too short: must be ' .
                  $Torrus::ACL::minPasswordLength . ' characters long');
            $ok = 0;
        }
        else
        {
            my $attrValues = $self->{'auth'}->setPassword( $uid, $password );
            $self->setUserAttributes( $uid, $attrValues );
            Info('Password set for ' . $uid);
        }
    }
    else
    {
        Error('Cannot change password for user ' . $uid .
              ': user does not exist');
        $ok = 0;
    }
    return $ok;
}


sub deleteUser
{
    my $self = shift;
    my $uid = shift;

    my $ok = 1;
    if( $self->userExists( $uid ) )
    {
        my $all = $self->{'redis'}->hgetall($self->{'users_hname'});
        while( scalar(@{$all}) > 0 )
        {
            my $key = shift @{$all};
            my $val = shift @{$all};

            my( $selector, $dbuid ) = split(':', $key);
            if( ( $selector eq 'gm' or $selector eq 'ua' ) and
                $dbuid eq $uid )
            {
                $self->_users_del($key);
            }
        }
        Info('User deleted: ' . $uid);
    }
    else
    {
        Error('Cannot delete user ' . $uid . ': user does not exist');
        $ok = 0;
    }
    return $ok;
}


sub setGroupAttribute
{
    my $self = shift;
    my $group = shift;
    my $attr = shift;
    my $val = shift;

    my $ok = 1;
    if( length( $attr ) == 0 or $attr =~ /\W/ )
    {
        Error('Invalid attribute name: ' . $attr);
        $ok = 0;
    }
    else
    {
        $self->_users_set( 'ga:' . $group . ':' . $attr, $val );
        $self->_users_list_add( 'gA:' . $group, $attr );
        if( $attr ne 'modified' )
        {
            $self->setGroupModified( $group );
        }
        Debug('Set ' . $attr . ' for ' . $group . ': ' . $val);
    }
    return $ok;
}


sub listGroupAttributes
{
    my $self = shift;
    my $group = shift;
    
    my $hash = $self->_users_list_read( 'gA:' . $group );
    return sort keys %{$hash};
}



sub setGroupModified
{
    my $self = shift;
    my $group = shift;

    $self->setGroupAttribute( $group, 'modified',
                              scalar( localtime( time() ) ) );
    return;
}


sub setPrivilege
{
    my $self = shift;
    my $group = shift;
    my $object = shift;
    my $privilege = shift;

    my $ok = 1;
    if( $self->groupExists( $group ) )
    {
        $self->{'redis'}->hset($self->{'acl_hname'},
                               $group.':'.$object.':'.$privilege, 1 );
        $self->setGroupModified( $group );
        Info('Privilege ' . $privilege . ' for object ' . $object .
             ' set for group ' . $group);
    }
    else
    {
        Error('Cannot set privilege for group ' . $group .
              ': group does not exist');
        $ok = 0;
    }
    return $ok;
}


sub clearPrivilege
{
    my $self = shift;
    my $group = shift;
    my $object = shift;
    my $privilege = shift;

    my $ok = 1;
    if( $self->groupExists( $group ) )
    {
        my $key = $group.':'.$object.':'.$privilege;
        if( $self->{'redis'}->hget($self->{'acl_hname'}, $key) )
        {
            $self->{'redis'}->hdel($self->{'acl_hname'}, $key);
            $self->setGroupModified( $group );
            Info('Privilege ' . $privilege . ' for object ' . $object .
                 ' revoked from group ' . $group);
        }
    }
    else
    {
        Error('Cannot revoke privilege from group ' . $group .
              ': group does not exist');
        $ok = 0;
    }
    return $ok;
}


sub listPrivileges
{
    my $self = shift;
    my $group = shift;

    my $ret = {};

    my $all = $self->{'redis'}->hgetall($self->{'acl_hname'});
    while( scalar(@{$all}) > 0 )
    {
        my $key = shift @{$all};
        my $val = shift @{$all};
        
        my( $dbgroup, $object, $privilege ) = split( ':', $key );
        if( $dbgroup eq $group )
        {
            $ret->{$object}{$privilege} = 1;
        }
    }

    return $ret;
}


sub clearConfig
{
    my $self = shift;

    $self->{'redis'}->del($self->{'acl_hname'});
    $self->{'redis'}->del($self->{'users_hname'});

    Info('Cleared the ACL configuration');
    return 1;
}


sub exportACL
{
    my $self = shift;
    my $exportfile = shift;
    my $exporttemplate = shift;
    
    my $ok = 
        eval( 'require Torrus::ACL::Export;' . 
              'Torrus::ACL::Export::exportACL($self, $exportfile,'.
              '$exporttemplate)' );
    if( $@ )
    {
        Error($@);
        return 0;
    }
    else
    {
        return $ok;
    }
}


sub importACL
{
    my $self = shift;
    my $importfile = shift;

    my $ok =
        eval('require Torrus::ACL::Import;' . 
             'Torrus::ACL::Import::importACL($self, $importfile)');
    
    if( $@ )
    {
        Error($@);
        return 0;
    }
    else
    {
        return $ok;
    }
}

1;


# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 4
# End:
