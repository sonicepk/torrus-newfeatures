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

# $Id$
# Stanislav Sinyagin <ssinyagin@yahoo.com>

# AxxessIT Ethernet over SDH switches, also known as
# Cisco ONS 15305 and 15302 (by January 2005)
# Probably later Cisco will update the software and it will need
# another Torrus discovery module.
# Company website: http://www.axxessit.no/

# Tested with:
#
# Cisco ONS 15305 software release 1.1.1

    

package Torrus::DevDiscover::AxxessIT;

use strict;
use Torrus::Log;


$Torrus::DevDiscover::registry{'AxxessIT'} = {
    'sequence'     => 500,
    'checkdevtype' => \&checkdevtype,
    'discover'     => \&discover,
    'buildConfig'  => \&buildConfig
    };


our %oiddef =
    (
     # AXXEDGE-MIB
     'axxEdgeTypes'                  => '1.3.6.1.4.1.7546.1.4.1.1',
     
     'axxEdgeWanPortMapTable'         => '1.3.6.1.4.1.7546.1.4.1.2.5.1.2',
     'axxEdgeWanPortMapSlotNumber'    => '1.3.6.1.4.1.7546.1.4.1.2.5.1.2.1.1',
     'axxEdgeWanPortMapPortNumber'    => '1.3.6.1.4.1.7546.1.4.1.2.5.1.2.1.2',

     'axxEdgeWanPortDescription'      => '1.3.6.1.4.1.7546.1.4.1.2.5.1.3.1.4',

     'axxEdgeEthPortMapTable'         => '1.3.6.1.4.1.7546.1.4.1.2.6.1.2',
     'axxEdgeEthPortMapSlotNumber'    => '1.3.6.1.4.1.7546.1.4.1.2.6.1.2.1.1',
     'axxEdgeEthPortMapPortNumber'    => '1.3.6.1.4.1.7546.1.4.1.2.6.1.2.1.2',
     
     'axxEdgeEthPortDescription'      => '1.3.6.1.4.1.7546.1.4.1.2.6.1.3.1.4',
     
     'axxEdgeDcnManagementPortMode'    => '1.3.6.1.4.1.7546.1.4.1.2.3.2.1.0',
     'axxEdgeDcnManagementPortIfIndex' => '1.3.6.1.4.1.7546.1.4.1.2.3.2.2.0',
     );


sub checkdevtype
{
    my $dd = shift;
    my $devdetails = shift;

    if( not $dd->oidBaseMatch
        ( 'axxEdgeTypes',
          $devdetails->snmpVar( $dd->oiddef('sysObjectID') ) ) )
    {
        return 0;
    }

    # Leave room for AXX155 devices, maybe someone needs them in the future
    $devdetails->setCap('axxEdge');

    my $data = $devdetails->data();

    $data->{'param'}{'ifindex-map'} = '$IFIDX_IFINDEX';

    $data->{'nameref'}{'ifNick'}        = 'axxInterfaceNick';
    $data->{'nameref'}{'ifSubtreeName'} = 'axxInterfaceNick';
    $data->{'nameref'}{'ifComment'}     = 'axxInterfaceComment';
    $data->{'nameref'}{'ifHumanName'}   = 'axxInterfaceHumanName';

    return 1;
}


sub discover
{
    my $dd = shift;
    my $devdetails = shift;

    my $data = $devdetails->data();
    my $session = $dd->session();

    if( $devdetails->hasCap('axxEdge') )
    {
        my $wanTable =
            $session->get_table( -baseoid =>
                                 $dd->oiddef('axxEdgeWanPortMapTable') );
        $devdetails->storeSnmpVars( $wanTable );

        my $wanDesc =
            $session->get_table( -baseoid =>
                                 $dd->oiddef('axxEdgeWanPortDescription') );
        $devdetails->storeSnmpVars( $wanDesc );
        
        my $ethTable =
            $session->get_table( -baseoid =>
                                 $dd->oiddef('axxEdgeEthPortMapTable') );
        $devdetails->storeSnmpVars( $ethTable );

        my $ethDesc =
            $session->get_table( -baseoid =>
                                 $dd->oiddef('axxEdgeEthPortDescription') );
        $devdetails->storeSnmpVars( $ethDesc );
        
        foreach my $ifIndex
            ( $devdetails->
              getSnmpIndices($dd->oiddef('axxEdgeWanPortMapSlotNumber')) )
        {
            my $interface = $data->{'interfaces'}{$ifIndex};
            next if not defined( $interface );

            my $slot =
                $devdetails->snmpVar
                ($dd->oiddef('axxEdgeWanPortMapSlotNumber') .'.'. $ifIndex);
            my $port =
                $devdetails->snmpVar
                ($dd->oiddef('axxEdgeWanPortMapPortNumber') .'.'. $ifIndex);
            
            my $desc =
                $devdetails->snmpVar
                ($dd->oiddef('axxEdgeWanPortDescription') .'.'.
                 $slot .'.'. $port);
            
            $interface->{'param'}{'interface-index'} = $ifIndex;

            $interface->{'axxInterfaceNick'} =
                sprintf( 'Wan_%d_%d', $slot, $port );

            $interface->{'axxInterfaceHumanName'} =
                sprintf( 'WAN %d/%d', $slot, $port );

            $interface->{'axxInterfaceComment'} =
                sprintf( 'WAN slot %d, port %d', $slot, $port );
            if( length( $desc ) > 0 )
            {
                $interface->{'axxInterfaceComment'} .= ' (' . $desc . ')';
            }
        }
        
        foreach my $ifIndex
            ( $devdetails->
              getSnmpIndices($dd->oiddef('axxEdgeEthPortMapSlotNumber')) )
        {
            my $interface = $data->{'interfaces'}{$ifIndex};
            next if not defined( $interface );

            my $slot =
                $devdetails->snmpVar
                ($dd->oiddef('axxEdgeEthPortMapSlotNumber') .'.'. $ifIndex);
            my $port =
                $devdetails->snmpVar
                ($dd->oiddef('axxEdgeEthPortMapPortNumber') .'.'. $ifIndex);

            my $desc =
                $devdetails->snmpVar
                ($dd->oiddef('axxEdgeEthPortDescription') .'.'.
                 $slot .'.'. $port);
            
            $interface->{'param'}{'interface-index'} = $ifIndex;

            $interface->{'axxInterfaceNick'} =
                sprintf( 'Eth_%d_%d', $slot, $port );

            $interface->{'axxInterfaceHumanName'} =
                sprintf( 'Ethernet %d/%d', $slot, $port );

            $interface->{'axxInterfaceComment'} =
                sprintf( 'Ethernet interface: slot %d, port %d',
                         $slot, $port );
            if( length( $desc ) > 0 )
            {
                $interface->{'axxInterfaceComment'} .= ' (' . $desc . ')';
            }
        }

        # Management interface
        {
            my $result = $dd->retrieveSnmpOIDs
                ( 'axxEdgeDcnManagementPortMode',
                  'axxEdgeDcnManagementPortIfIndex');

            if( defined( $result ) )
            {
                if( $result->{'axxEdgeDcnManagementPortMode'} != 2 )
                {
                    Warning('Non-IP mode of Management port is not supported');
                }
                else
                {
                    my $ifIndex = $result->{'axxEdgeDcnManagementPortIfIndex'};
                    
                    my $interface = $data->{'interfaces'}{$ifIndex};
            
                    $interface->{'param'}{'interface-index'} = $ifIndex;

                    $interface->{'axxInterfaceNick'} = 'Management';

                    $interface->{'axxInterfaceHumanName'} = 'Management';

                    $interface->{'axxInterfaceComment'} = 'Management port';
                }
            }
        }
        
        foreach my $ifIndex ( keys %{$data->{'interfaces'}} )
        {
            if( not defined( $data->{'interfaces'}{$ifIndex}->
                             {'param'}{'interface-index'} ) )
            {
                delete $data->{'interfaces'}{$ifIndex};
            }
        }
    }
    
    return 1;
}


sub buildConfig
{
    my $devdetails = shift;
    my $cb = shift;
    my $devNode = shift;

}


1;


# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 4
# End:
