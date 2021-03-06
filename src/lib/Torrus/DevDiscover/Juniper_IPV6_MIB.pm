#  Copyright (C) 2014  Stanislav Sinyagin
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

# Juniper IPv6 MIB traffic statistics


package Torrus::DevDiscover::Juniper_IPV6_MIB;

use strict;
use warnings;

use Torrus::Log;
use Data::Dumper;

$Torrus::DevDiscover::registry{'Juniper_IPV6_MIB'} = {
    'sequence'     => 700,
    'checkdevtype' => \&checkdevtype,
    'discover'     => \&discover,
    'buildConfig'  => \&buildConfig
    };



our %oiddef =
    (
     # IP-MIB
     #'jnxIpv6IfStatsEntry'=> '1.3.6.1.4.1.2636.3.11.1.3.1.1',
     'jnxIpv6IfInOctets'    => '1.3.6.1.4.1.2636.3.11.1.3.1.1.1',
     'jnxIpv6IfOutOctets'   => '1.3.6.1.4.1.2636.3.11.1.3.1.1.2',
     );

my $ipver = 'ipv6';

my %inetVersion = (ipv4 => 1, ipv6 => 2);


sub checkdevtype
{
    my $dd = shift;
    my $devdetails = shift;

    my $data = $devdetails->data();
    my $matched = 0;
    #print "IPv6 \n";

    if( $devdetails->paramEnabled('Juniper_IPV6_MIB::ipv6-stats') and
        $dd->checkSnmpTable('jnxIpv6IfInOctets') )
    {
        $matched = 1;
        $devdetails->setCap('jnxIpv6IfStatsEntry');
    }

    return $matched;
}


sub discover
{
    my $dd = shift;
    my $devdetails = shift;

    my $data = $devdetails->data();
    my $session = $dd->session();

        if( $devdetails->hasCap('jnxIpv6IfStatsEntry') )
        {
            my $ifStats = $dd->walkSnmpTable('jnxIpv6IfInOctets');
            foreach my $ifIndex (keys %{$ifStats})
            {
                my $interface = $data->{'interfaces'}{$ifIndex};
                next if not defined($interface);
                next if $interface->{'excluded'};

                $data->{'ipIfStats'}{$ifIndex} = 1;
            }
        }
    return 1;
}



sub buildConfig
{
    my $devdetails = shift;
    my $cb = shift;
    my $devNode = shift;

    my $data = $devdetails->data();


        # tokenset member interfaces of the form
        # Format: tset:intf,intf; tokenset:intf,intf;
        # Format for global parameter:
        #     tset:host/intf,host/intf; tokenset:host/intf,host/intf;
        my %tsetMember;
        my %tsetMemberApplied;
        foreach my $memList
            ( split( /\s*;\s*/,
                     $devdetails->paramString
                     ('Juniper_IPV6_MIB::tokenset-members') ) )
        {
            my ($tset, $list) = split( /\s*:\s*/, $memList );
            foreach my $intfName ( split( /\s*,\s*/, $list ) )
            {
                if( $intfName =~ /\// )
                {
                    my( $host, $intf ) = split( '/', $intfName );
                    if( $host eq $devdetails->param('snmp-host') )
                    {
                        $tsetMember{$intf}{$tset} = 1;
                    }
                }
                else
                {
                    $tsetMember{$intfName}{$tset} = 1;
                }
            }
        }

        # External storage serviceid assignment
        # Params: Juniper_IPV6_MIB::ipv4-external-serviceid,
        #         Juniper_IPV6_MIB::ipv6-external-serviceid,
        my %extStorage;
        my %extStorageTrees;
        
        foreach my $srvDef
            ( split( /\s*,\s*/,
                     $devdetails->paramString
                     ('Juniper_IPV6_MIB::' . 'ipv6' . '-external-serviceid') ) )
        {
            my ( $serviceid, $intfName, $direction, $trees ) =
                split( /\s*:\s*/, $srvDef );
            
            if( $intfName =~ /\// )
            {
                my( $host, $intf ) = split( '/', $intfName );
                if( $host eq $devdetails->param('snmp-host') )
                {
                    $intfName = $intf;
                }
                else
                {
                    $intfName = undef;
                }
            }
            
            if( defined($intfName) and $intfName ne '' )
            {
                if( defined( $trees ) )
                {
                    # Trees are listed with '|' as separator,
                    # whereas compiler expects commas
                    
                    $trees =~ s/\s*\|\s*/,/g;
                }
                
                if( $direction eq 'Both' )
                {
                    $extStorage{$intfName}{'In'} = $serviceid . '_IN';
                    $extStorageTrees{$serviceid . '_IN'} = $trees;
                    
                    $extStorage{$intfName}{'Out'} = $serviceid . '_OUT';
                    $extStorageTrees{$serviceid . '_OUT'} = $trees;
                }
                else
                {
                    $extStorage{$intfName}{$direction} = $serviceid;
                    $extStorageTrees{$serviceid} = $trees;
                }
            }
        }
        
        my $subtreeName = 'IPv6_Stats';

        my $subtreeParam = {
            'precedence'          => '-600',
            'node-display-name'   => 'IPv6 traffic statistics',
            'comment'        => 'per-interface in/out bytes for IPv6',
            'ipmib-ipver' => $inetVersion{ipv6},
            'ipmib-ipver-name' => 'IPv6',
            'ipmib-ipver-nameuc' => 'IPV6',
        };

        my $subtreeNode =
            $cb->addSubtree( $devNode, $subtreeName, $subtreeParam,
                             ['Juniper_IPV6_MIB::jnxIpv6-ipmib-subtree']);

        my $precedence = 1000;
        foreach my $ifIndex ( sort {$a<=>$b} %{$data->{'ipIfStats'}} )
        {
            my $interface = $data->{'interfaces'}{$ifIndex};
            next if not defined($interface);
            next if $interface->{'excluded'};

            my $ifSubtreeName =
                $interface->{$data->{'nameref'}{'ifSubtreeName'}};

            my $ifParam = {};

            $ifParam->{'interface-index'} = $ifIndex;

            $ifParam->{'collector-timeoffset-hashstring'} =
                '%system-id%:%interface-nick%';
            $ifParam->{'precedence'} = $precedence;

            $ifParam->{'graph-title'} =
                '%system-id%:%interface-name% ' . 'IPV6';

            $ifParam->{'interface-name'} =
                $interface->{$data->{'nameref'}{'ifReferenceName'}};
            $ifParam->{'interface-nick'} =
                $interface->{$data->{'nameref'}{'ifNick'}};
            $ifParam->{'node-display-name'} =
                $interface->{$data->{'nameref'}{'ifReferenceName'}};

            $ifParam->{'nodeid-interface'} =
                $ipver . '-' .
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}};

            if( defined($data->{'nameref'}{'ifComment'}) and
                defined($interface->{$data->{'nameref'}{'ifComment'}}) )
            {
                $ifParam->{'comment'} =
                    $interface->{$data->{'nameref'}{'ifComment'}};
            }

            my $templates = ['Juniper_IPV6_MIB::jnxipifstats-hcoctets'];
            my $childParams = {};

            my $actionsRef =
                $data->{'ipIfStats_SelectorActions'}{$ipver}{$ifIndex};
            if( defined($actionsRef) )
            {
                foreach my $dir ( 'In', 'Out' )
                {
                    if( defined( $actionsRef->{$dir . 'BytesMonitor'} ) )
                    {
                        $childParams->{
                            'Bytes_' . $dir}->{'monitor'} =
                                $actionsRef->{$dir . 'BytesMonitor'};
                    }

                    if( defined( $actionsRef->{$dir . 'BytesParameters'} ) )
                    {
                        my @pairs =
                            split('\s*;\s*',
                                  $actionsRef->{$dir . 'BytesParameters'});

                        foreach my $pair( @pairs )
                        {
                            my ($param, $val) = split('\s*=\s*', $pair);
                            $childParams->{
                                'Bytes_' . $dir}->{$param} = $val;
                        }
                    }
                }

                if( defined( $actionsRef->{'TokensetMember'} ) )
                {
                    foreach my $tset
                        ( split('\s*,\s*', $actionsRef->{'TokensetMember'}) )
                    {
                        $tsetMember{$ifSubtreeName}{$tset} = 1;
                    }
                }
            }

            if( defined( $extStorage{$ifSubtreeName} ) )
            {
                foreach my $dir ( 'In', 'Out' )
                {
                    if( defined( $extStorage{$ifSubtreeName}{$dir} ) )
                    {
                        my $serviceid = $extStorage{$ifSubtreeName}{$dir};

                        my $params = {
                            'storage-type'      => 'rrd,ext',
                            'ext-service-id'    => $serviceid,
                            'ext-service-units' => 'bytes' };
                        
                        if( defined( $extStorageTrees{$serviceid} )
                            and $extStorageTrees{$serviceid} ne '' )
                        {
                            $params->{'ext-service-trees'} =
                                $extStorageTrees{$serviceid};
                        }

                        foreach my $param ( keys %{$params} )
                        {
                            $childParams->{
                                'Bytes_' . $dir}{$param} = $params->{$param};
                        }
                    }
                }
            }

            if( scalar(@{$templates}) > 0 )
            {
                my $intfNode = $cb->addSubtree( $subtreeNode, $ifSubtreeName,
                                                $ifParam, $templates );

                if( defined( $tsetMember{$ifSubtreeName} ) )
                {
                    my $tsetList =
                        join( ',', sort keys %{$tsetMember{$ifSubtreeName}} );

                    $childParams->{'InOut_bps'}->{'tokenset-member'} =
                        $tsetList;
                    $tsetMemberApplied{$ifSubtreeName} = 1;
                }

                if( scalar(keys %{$childParams}) > 0 )
                {
                    foreach my $childName ( sort keys %{$childParams} )
                    {
                        $cb->addLeaf
                            ( $intfNode, $childName,
                              $childParams->{$childName} );
                    }
                }
            }
        }

        if( scalar(keys %tsetMember) > 0 )
        {
            my @failedIntf;
            foreach my $intfName ( keys %tsetMember )
            {
                if( not $tsetMemberApplied{$intfName} )
                {
                    push( @failedIntf, $intfName );
                }
            }

            if( scalar( @failedIntf ) > 0 )
            {
                Warn('Juniper_IPV6_MIB statistics for the following ' .
                     'interfaces were not added to tokensets, ' .
                     'probably because they do not exist or are explicitly ' .
                     'excluded: ' .
                     join(' ', sort @failedIntf));
            }
        }

    return;
}



#######################################
# Selectors interface
#
$Torrus::DevDiscover::selectorsRegistry{'Juniper_IPV6_MIB_v6'} = {
    'getObjects'      => \&v6_getSelectorObjects,
    'getObjectName'   => \&v6_getSelectorObjectName,
    'checkAttribute'  => \&v6_checkSelectorAttribute,
    'applyAction'     => \&v6_applySelectorAction,
};

sub v6_getSelectorObjects {getSelectorObjects('ipv6', @_)};
sub v6_getSelectorObjectName {getSelectorObjectName('ipv6', @_)};
sub v6_checkSelectorAttribute {checkSelectorAttribute('ipv6', @_)};
sub v6_applySelectorAction {applySelectorAction('ipv6', @_)};


## Objects are interface indexes

sub getSelectorObjects
{
    my $ipver = shift;
    my $devdetails = shift;
    my $objType = shift;
    return( sort {$a<=>$b} keys
            (%{$devdetails->data()->{'ipIfStats'}}) );
}


sub checkSelectorAttribute
{
    my $ipver = shift;
    my $devdetails = shift;
    my $object = shift;
    my $objType = shift;
    my $attr = shift;
    my $checkval = shift;

    my $data = $devdetails->data();
    my $interface = $data->{'interfaces'}{$object};
    if( not defined($interface) or $interface->{'excluded'} )
    {
        return 0;
    }

    if( $attr =~ /^ifSubtreeName\d*$/ )
    {
        my $value = $interface->{$data->{'nameref'}{'ifSubtreeName'}};
        my $match = 0;
        foreach my $chkexpr ( split( /\s+/, $checkval ) )
        {
            if( $value =~ $chkexpr )
            {
                $match = 1;
                last;
            }
        }
        return $match;
    }

    return 0;
}


sub getSelectorObjectName
{
    my $ipver = shift;
    my $devdetails = shift;
    my $object = shift;
    my $objType = shift;

    my $data = $devdetails->data();
    my $interface = $data->{'interfaces'}{$object};
    return $interface->{$data->{'nameref'}{'ifSubtreeName'}};
}


our %knownSelectorActions =
    (
     'InBytesMonitor'    => 'Juniper_IPV6_MIB',
     'OutBytesMonitor'   => 'Juniper_IPV6_MIB',
     'InBytesParameters' => 'Juniper_IPV6_MIB',
     'OutBytesParameters' => 'Juniper_IPV6_MIB',
     'TokensetMember' => 'Juniper_IPV6_MIB',
    );


sub applySelectorAction
{
    my $ipver = shift;
    my $devdetails = shift;
    my $object = shift;
    my $objType = shift;
    my $action = shift;
    my $arg = shift;

    my $data = $devdetails->data();

    if( defined( $knownSelectorActions{$action} ) )
    {
        if( not $devdetails->isDevType( $knownSelectorActions{$action} ) )
        {
            Error('Action ' . $action . ' is applied to a device that is ' .
                  'not of type ' . $knownSelectorActions{$action} .
                  ': ' . $devdetails->param('system-id'));
        }
        $data->{'ipIfStats_SelectorActions'}{$object}{$action} = $arg;
    }
    else
    {
        Error('Unknown Juniper_IPV6_MIB selector action: ' . $action);
    }

    return;
}







1;


# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 4
# End:
