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

# Cisco IOS devices discovery

package Torrus::DevDiscover::CiscoIOS;

use strict;
use warnings;

use Torrus::Log;


$Torrus::DevDiscover::registry{'CiscoIOS'} = {
    'sequence'     => 510,
    'checkdevtype' => \&checkdevtype,
    'discover'     => \&discover,
    'buildConfig'  => \&buildConfig
};


our %oiddef =
    (
     # CISCO-PRODUCTS-MIB
     'ciscoLS1010'                       => '1.3.6.1.4.1.9.1.107',
     # CISCO-IMAGE-MIB
     'ciscoImageTable'                   => '1.3.6.1.4.1.9.9.25.1.1',
     # CISCO-ENHANCED-IMAGE-MIB
     'ceImageTable'                      => '1.3.6.1.4.1.9.9.249.1.1.1',
     # OLD-CISCO-MEMORY-MIB
     'bufferElFree'                      => '1.3.6.1.4.1.9.2.1.9.0',
     # CISCO-IPSEC-FLOW-MONITOR-MIB
     'cipSecGlobalHcInOctets'            => '1.3.6.1.4.1.9.9.171.1.3.1.4.0',
     # CISCO-BGP4-MIB
     'cbgpPeerAddrFamilyName'            => '1.3.6.1.4.1.9.9.187.1.2.3.1.3',
     'cbgpPeerAcceptedPrefixes'          => '1.3.6.1.4.1.9.9.187.1.2.4.1.1',
     'cbgpPeerPrefixAdminLimit'          => '1.3.6.1.4.1.9.9.187.1.2.4.1.3',
     # CISCO-CAR-MIB
     'ccarConfigType'                    => '1.3.6.1.4.1.9.9.113.1.1.1.1.3',
     'ccarConfigAccIdx'                  => '1.3.6.1.4.1.9.9.113.1.1.1.1.4',
     'ccarConfigRate'                    => '1.3.6.1.4.1.9.9.113.1.1.1.1.5',
     'ccarConfigLimit'                   => '1.3.6.1.4.1.9.9.113.1.1.1.1.6',
     'ccarConfigExtLimit'                => '1.3.6.1.4.1.9.9.113.1.1.1.1.7',
     'ccarConfigConformAction'           => '1.3.6.1.4.1.9.9.113.1.1.1.1.8',
     'ccarConfigExceedAction'            => '1.3.6.1.4.1.9.9.113.1.1.1.1.9',
     # CISCO-VPDN-MGMT-MIB
     'cvpdnSystemTunnelTotal'            => '1.3.6.1.4.1.9.10.24.1.1.4.1.2',
     # CISCO-WAN-3G-MIB
     'c3gStandard'                       => '1.3.6.1.4.1.9.9.661.1.1.1.1',
     # CISCO-PORT-QOS-MIB
     'cportQosDropPkts'                  => '1.3.6.1.4.1.9.9.189.1.3.2.1.7',
    );


# Not all interfaces are normally needed to monitor.
# You may override the interface filtering in devdiscover-siteconfig.pl:
# redefine $Torrus::DevDiscover::CiscoIOS::interfaceFilter
# or define $Torrus::DevDiscover::CiscoIOS::interfaceFilterOverlay

our $interfaceFilter;
our $interfaceFilterOverlay;
my %ciscoInterfaceFilter;

if( not defined( $interfaceFilter ) )
{
    $interfaceFilter = \%ciscoInterfaceFilter;
}


# Key is some unique symbolic name, does not mean anything
# ifType is the number to match the interface type
# ifDescr is the regexp to match the interface description
%ciscoInterfaceFilter =
    (
     'Null0' => {
         'ifType'  => 1,                      # other
         'ifDescr' => '^Null'
     },

     'E1 N/N/N' => {
         'ifType'  => 18,                     # ds1
         'ifDescr' => '^E1'
     },

     'Virtual-AccessN' => {
         'ifType'  => 23,                     # ppp
         'ifDescr' => '^Virtual-Access'
     },
     
     'LoopbackN'  => {
         'ifType'  => 24,                     # softwareLoopback
         'ifDescr' => '^Loopback'
     },

     'SerialN:N-Bearer Channel' => {
         'ifType'  => 81,                     #  ds0, Digital Signal Level 0
         'ifDescr' => '^Serial.*Bearer\s+Channel'
     },

     'Voice Encapsulation (POTS) Peer: N' => {
         'ifType'  => 103                     # voiceEncap
     },

     'Voice Over IP Peer: N' => {
         'ifType'  => 104                     # voiceOverIp
     },

     'ATMN/N/N.N-atm subif' => {
         'ifType'  => 134,                    # atmSubInterface
         'ifDescr' => '^ATM[0-9\/]+\.[0-9]+\s+subif'
     },
     
     'BundleN' => {
         'ifType'  => 127,                    # docsCableMaclayer
         'ifDescr' => '^Bundle'
     },

     'EOBCN/N' => {
         'ifType'  => 53,                     # propVirtual
         'ifDescr' => '^EOBC'
     },

     'FIFON/N' => {
         'ifType'  => 53,                     # propVirtual
         'ifDescr' => '^FIFO'
     },
     
     'vfc' => {
         'ifType'  => 56,                     # virtualFibreChannel
         'ifDescr' => '^vfc'
     },
    );

our %tunnelType =
    (
     # CISCO-VPDN-MGMT-MIB Tunnel Types
     '1' => 'L2F',
     '2' => 'L2TP',
     '3' => 'PPTP'
    );


sub checkdevtype
{
    my $dd = shift;
    my $devdetails = shift;

    if( not $devdetails->isDevType('CiscoGeneric') )
    {
        return 0;
    }

    # first, try to find IOS or IOS XR in sysDescr
    my $sysDescr = $devdetails->snmpVar($dd->oiddef('sysDescr'));
    my $found = 0;
    if( defined($sysDescr) and
        index( $sysDescr, 'Cisco IOS Software' ) >= 0 )
    {
        $found = 1;
    }
    elsif( defined($sysDescr) and
           index( $sysDescr, 'Cisco IOS XR Software' ) >= 0 )
    {
        $found = 1;
        $devdetails->setCap('CiscoIOSXR');
    }
    elsif( defined($sysDescr) and
           index( $sysDescr, 'Cisco NX-OS' ) >= 0 )
    {
        # nexus implements the class-based qoS MIB, so we treat it as
        # an IOS device
        $found = 1;
        $devdetails->setCap('CiscoNXOS');
    }
    else
    {
        # fall back to software image table
        if( $dd->checkSnmpTable('ciscoImageTable') )
        {
            $found = 1;
        }
        elsif( $dd->checkSnmpTable('ceImageTable') )
        {
            $found = 1;
            $devdetails->setCap('CiscoIOSXR');
        }
    }

    if( not $found )
    {
        return 0;
    }
    
    # On some Layer3 switching devices, VlanXXX interfaces give some
    # useful stats, while on others the stats are not relevant at all
    
    if( $devdetails->paramDisabled('CiscoIOS::enable-vlan-interfaces') )
    {
        $interfaceFilter->{'VlanN'} = {
            'ifType'  => 53,                     # propVirtual
            'ifDescr' => '^Vlan\d+'
        };
    }

    # same thing with unrouted VLAN interfaces
    if( $devdetails->paramDisabled
        ('CiscoIOS::enable-unrouted-vlan-interfaces'))
    {
        $interfaceFilter->{'unrouted VLAN N'} = {
            'ifType'  => 53,                     # propVirtual
            'ifDescr' => '^unrouted\s+VLAN\s+\d+'
        };
    }

    # sometimes we want Dialer interface stats
    if( $devdetails->paramDisabled('CiscoIOS::enable-dialer-interfaces') )
    {
        $interfaceFilter->{'DialerN'} = {
            'ifType'  => 23,                     # ppp
            'ifDescr' => '^Dialer'
            };
        $interfaceFilter->{'DialerN_ML'} = {
            'ifType'  => 108,                    # pppMultilinkBundle
            'ifDescr' => '^Dialer'
            };
    }

    &Torrus::DevDiscover::RFC2863_IF_MIB::addInterfaceFilter
        ($devdetails, $interfaceFilter);

    if( defined( $interfaceFilterOverlay ) )
    {
        &Torrus::DevDiscover::RFC2863_IF_MIB::addInterfaceFilter
            ($devdetails, $interfaceFilterOverlay);
    }

    $devdetails->setCap('interfaceIndexingManaged');

    if( $devdetails->hasCap('CiscoNXOS') or
        $devdetails->paramEnabled('CiscoIOS::ifindex-persist') )
    {
        $devdetails->setCap('interfaceIndexingPersistent');
    }

    return 1;
}


my %ccarConfigTypeTranslation =
    ( 1 => 'all',
      2 => 'quickAcc',
      3 => 'standardAcc' );

my %ccarActionTranslation =
    ( 1 => 'drop',
      2 => 'xmit',
      3 => 'continue',
      4 => 'precedXmit',
      5 => 'precedCont' );



sub discover
{
    my $dd = shift;
    my $devdetails = shift;

    my $session = $dd->session();
    my $data = $devdetails->data();

    # fixing the interface indexing and referencing schema
    $data->{'nameref'}{'ifSubtreeName'}   = 'ifDescrT';
    $data->{'nameref'}{'ifReferenceName'} = 'ifDescr';
    $data->{'nameref'}{'ifNick'} = 'ifNameT';
    $data->{'nameref'}{'ifComment'} = 'ifAlias';

    # Old mkroutercfg used cisco-interface-counters
    if( $Torrus::DevDiscover::CiscoIOS::useCiscoInterfaceCounters )
    {
        foreach my $interface ( values %{$data->{'interfaces'}} )
        {
            $interface->{'hasHCOctets'} = 0;
            $interface->{'hasOctets'} = 0;
            push( @{$interface->{'templates'}},
                  'CiscoIOS::cisco-interface-counters' );
        }
    }

    if( $devdetails->paramEnabled('CiscoIOS::enable-membuf-stats') )
    {
        # Old Memory Buffers, if we have bufferElFree we assume
        # the rest as they are "required"

        if( $dd->checkSnmpOID('bufferElFree') )
        {
            $devdetails->setCap('old-ciscoMemoryBuffers');
            push( @{$data->{'templates'}},
                  'CiscoIOS::old-cisco-memory-buffers' );
        }
    }

    if( $devdetails->paramDisabled('CiscoIOS::disable-ipsec-stats') )
    {
        if( $dd->checkSnmpOID('cipSecGlobalHcInOctets') )
        {
            $devdetails->setCap('ciscoIPSecGlobalStats');
            push( @{$data->{'templates'}},
                  'CiscoIOS::cisco-ipsec-flow-globals' );
        }
        
        if( $dd->oidBaseMatch
            ( 'ciscoLS1010',
              $devdetails->snmpVar( $dd->oiddef('sysObjectID') ) ) )
        {
            $data->{'param'}{'snmp-oids-per-pdu'} = 10;
        }
    }

    if( $devdetails->paramDisabled('CiscoIOS::disable-bgp-stats') )
    {
        my $peerTable = $dd->walkSnmpTable('cbgpPeerAcceptedPrefixes');
        if( scalar(keys %{$peerTable}) > 0 )
        {
            $devdetails->setCap('CiscoBGP');

            my $limitsTable = $dd->walkSnmpTable('cbgpPeerPrefixAdminLimit');
            
            $data->{'cbgpPeers'} = {};
            
            # retrieve AS numbers for neighbor peers
            Torrus::DevDiscover::RFC1657_BGP4_MIB::discover($dd, $devdetails);
            
            # list of indices for peers that are not IPv4 Unicast
            my @nonV4Unicast;

            # Number of peers for each AS
            my %asNumbers;    

            foreach my $INDEX ( keys %{$peerTable} )
            {
                my ($a1, $a2, $a3, $a4, $afi, $safi) = split(/\./, $INDEX);
                my $peerIP = join('.', $a1, $a2, $a3, $a4);

                my $peer = {
                    'peerIP' => $peerIP,
                    'addrFamily' => 'IPv4 Unicast'
                };
                
                if( $afi != 1 and $safi != 1 )
                {
                    push( @nonV4Unicast, $INDEX );
                }

                {
                    my $desc =
                        $devdetails->paramString
                        ('peer-ipaddr-description-' .
                         join('_', split('\.', $peerIP)));
                    if( $desc ne '' )
                    {
                        $peer->{'description'} = $desc;
                    }
                }
                
                my $peerAS = $data->{'bgpPeerAS'}{$peerIP};
                if( defined( $peerAS ) )
                {
                    $peer->{'peerAS'} = $data->{'bgpPeerAS'}{$peerIP};
                    $asNumbers{$peer->{'peerAS'}}++;

                    my $desc =
                        $devdetails->paramString
                        ('bgp-as-description-' . $peerAS);
                    if( $desc ne '' )
                    {
                        if( defined( $peer->{'description'} ) )
                        {
                            Warn('Conflicting descriptions for peer ' .
                                 $peerIP);
                        }
                        $peer->{'description'} = $desc;
                    }
                }
                else
                {
                    Error('Cannot find AS number for BGP peer ' . $peerIP);
                    next;
                }

                if( defined( $peer->{'description'} ) )
                {
                    $peer->{'description'} .= ' ';
                }
                $peer->{'description'} .= '[' . $peerIP . ']';

                $peer->{'prefixLimit'} =  $limitsTable->{$INDEX};
                
                $data->{'cbgpPeers'}{$INDEX} = $peer;                
            }

            if( scalar( @nonV4Unicast ) > 0 )
            {
                my $addrFamTable =
                    $dd->walkSnmpTable('cbgpPeerAddrFamilyName');
                
                foreach my $INDEX ( @nonV4Unicast )
                {
                    my $peer = $data->{'cbgpPeers'}{$INDEX};
                    my $fam = $addrFamTable->{$INDEX};
                    $peer->{'addrFamily'} = $fam;
                    $peer->{'otherAddrFamily'} = 1;
                    $peer->{'description'} .= ' ' . $fam;
                }
            }

            # Construct the subtree names from AS, peer IP, and address
            # family
            foreach my $INDEX ( keys %{$data->{'cbgpPeers'}} )
            {
                my $peer = $data->{'cbgpPeers'}{$INDEX};
                
                my $subtreeName = 'AS' . $peer->{'peerAS'};
                if( $asNumbers{$peer->{'peerAS'}} > 1 )
                {
                    $subtreeName .= '_' . $peer->{'peerIP'};
                }
                
                if( $peer->{'otherAddrFamily'} )
                {
                    my $fam = $data->{'cbgpPeers'}{$INDEX}{'addrFamily'};
                    $fam =~ s/\W/_/g;
                    $subtreeName .= '_' . $fam;
                }
                
                $peer->{'subtreeName'} = $subtreeName;
            }
        }
    }

    
    if( $devdetails->paramDisabled('CiscoIOS::disable-car-stats') )
    {
        my $ccarConfigType = $dd->walkSnmpTable('ccarConfigType');
        if( scalar(keys %{$ccarConfigType}) > 0 )
        {
            $devdetails->setCap('CiscoCAR');
            $data->{'ccar'} = {};

            my $ccarConfigAccIdx = $dd->walkSnmpTable('ccarConfigAccIdx');
            my $ccarConfigRate = $dd->walkSnmpTable('ccarConfigRate');
            my $ccarConfigLimit = $dd->walkSnmpTable('ccarConfigLimit');
            my $ccarConfigExtLimit = $dd->walkSnmpTable('ccarConfigExtLimit');
            my $ccarConfigConformAction =
                $dd->walkSnmpTable('ccarConfigConformAction');
            my $ccarConfigExceedAction =
                $dd->walkSnmpTable('ccarConfigExceedAction');
            
            while( my($INDEX, $confType) = each %{$ccarConfigType} )
            {
                my ($ifIndex, $dir, $carIndex) = split(/\./, $INDEX);
                my $interface = $data->{'interfaces'}{$ifIndex};
                if( not defined($interface) or $interface->{'excluded'} )
                {
                    next;
                }

                my $car = {
                    'ifIndex'   => $ifIndex,
                    'direction' => $dir,
                    'carIndex'  => $carIndex };

                $car->{'configType'} =
                    $ccarConfigTypeTranslation{ $ccarConfigType->{$INDEX} };
                $car->{'accIdx'} = $ccarConfigAccIdx->{$INDEX};
                $car->{'rate'} = $ccarConfigRate->{$INDEX};
                $car->{'limit'} = $ccarConfigLimit->{$INDEX};
                $car->{'extLimit'} = $ccarConfigExtLimit->{$INDEX};
                $car->{'conformAction'} =
                    $ccarActionTranslation{
                        $ccarConfigConformAction->{$INDEX} };
                $car->{'exceedAction'} =
                    $ccarActionTranslation{
                        $ccarConfigExceedAction->{$INDEX} };

                $data->{'ccar'}{$INDEX} = $car;
            }
        }
    }


    if( $devdetails->paramDisabled('CiscoIOS::disable-vpdn-stats') )
    {
        if( $dd->checkSnmpTable( 'cvpdnSystemTunnelTotal' ) )
        {
            # Find the Tunnel type
            my $cvpdnSystemTunnelTotal =
                $dd->walkSnmpTable('cvpdnSystemTunnelTotal');
            
            if( scalar(keys %{$cvpdnSystemTunnelTotal}) > 0 )
            {
                $devdetails->setCap('ciscoVPDN');

                # VPDN indexing: 1: l2f, 2: l2tp, 3: pptp
                foreach my $typeIndex
                    (keys %{$cvpdnSystemTunnelTotal})
                {
                    Debug("CISCO-VPDN-MGMT-MIB: found Tunnel type " .
                          $tunnelType{$typeIndex} );
                    
                    $data->{'ciscoVPDN'}{$typeIndex} = $tunnelType{$typeIndex};
                }
            }
        }
    }

    if( $devdetails->paramDisabled('CiscoIOS::disable-3g-stats') )
    {
        my $table = $dd->walkSnmpTable('c3gStandard');        
        while( my( $phy, $val ) = each %{$table} )
        {
            if( $val == 2 )
            {
                $devdetails->setCap('Cisco3G');
                my $phyName = $data->{'entityPhysical'}{$phy}{'name'};
                if( not defined( $phyName ) )
                {
                    $phyName = 'Cellular Modem';
                }
                
                $data->{'cisco3G'}{$phy} = {
                    'name'   => $phyName,
                    'standard' => 'gsm',
                };
            }
            else
            {
                Warn('CISCO-WAN-3G-MIB: CDMA statistics are ' .
                     'not yet implemented');
            }
        }

        my $tokenset = $devdetails->paramString('CiscoIOS::3g-stats-tokenset');
        if( $tokenset ne '')
        {
            $data->{'cisco3G_tokenset'} = $tokenset;
        }
    }


    if( $devdetails->paramDisabled('CiscoIOS::disable-port-qos-stats') )
    {
        my $table = $dd->walkSnmpTable('cportQosDropPkts');
        if( scalar(keys %{$table}) > 0 )
        {            
            $devdetails->setCap('CiscoPortQos');
            $data->{'ciscoPortQos'} = {};
            
            foreach my $qos_entry (keys %{$table})
            {
                my($ifIndex, $direction, $qos_index) =
                    split(/\./o, $qos_entry);
                
                $data->{'ciscoPortQos'}{$qos_entry} = {
                    'ifIndex' => $ifIndex,
                    'direction' => ($direction==1)?'ingress':'egress',
                    'qosidx' => $qos_index,
                };                
            }
        }
    }
    
    
    if( $devdetails->paramEnabled('CiscoIOS::short-device-comment')
        and
        defined($data->{'param'}{'comment'}) )
    {
        # Remove serials from device comment
        # 1841 chassis, Hw Serial#: 3625140487, Hw Revision: 6.0
        
        $data->{'param'}{'comment'} =~ s/, Hw.*//o;
    }

    return 1;
}


sub buildConfig
{
    my $devdetails = shift;
    my $cb = shift;
    my $devNode = shift;

    my $data = $devdetails->data();

    if( $devdetails->hasCap('CiscoBGP') )
    {
        my $countersNode =
            $cb->addSubtree( $devNode, 'BGP_Prefixes',
                             {
                                 'node-display-name' => 'BGP Prefixes',
                                 'comment' => 'Accepted prefixes',
                             } );

        foreach my $INDEX ( sort
                            { $data->{'cbgpPeers'}{$a}{'subtreeName'} cmp
                                  $data->{'cbgpPeers'}{$b}{'subtreeName'} }
                            keys %{$data->{'cbgpPeers'}} )
        {
            my $peer = $data->{'cbgpPeers'}{$INDEX};

            my $param = {
                'peer-index'           => $INDEX,
                'peer-ipaddr'          => $peer->{'peerIP'},
                'comment'              => $peer->{'description'},
                'descriptive-nickname' => $peer->{'subtreeName'},
                'precedence'           => 65000 - $peer->{'peerAS'}
            };

            if( defined( $peer->{'prefixLimit'} ) and
                $peer->{'prefixLimit'} > 0 )
            {
                $param->{'upper-limit'} = $peer->{'prefixLimit'};
                $param->{'graph-upper-limit'} = $peer->{'prefixLimit'} * 1.03;
            }
            
            $cb->addLeaf
                ( $countersNode, $peer->{'subtreeName'}, $param,
                  ['CiscoIOS::cisco-bgp'] );
        }
    }

    
    if( $devdetails->hasCap('CiscoCAR') )
    {
        my $countersNode =
            $cb->addSubtree( $devNode, 'CAR_Stats', {
                'comment' => 'Committed Access Rate statistics',
                'node-display-name' => 'CAR', },
                             ['CiscoIOS::cisco-car-subtree']);
        
        foreach my $INDEX ( sort keys %{$data->{'ccar'}} )
        {
            my $car = $data->{'ccar'}{$INDEX};
            my $interface = $data->{'interfaces'}{$car->{'ifIndex'}};
            
            my $subtreeName =
                $interface->{$data->{'nameref'}{'ifSubtreeName'}};

            $subtreeName .= ($car->{'direction'} == 1) ? '_IN':'_OUT';
            if( $car->{'carIndex'} > 1 )
            {
                $subtreeName .= '_' . $car->{'carIndex'};
            }
            
            my $ifParam = {
                'searchable' => 'yes',
                'car-direction' => $car->{'direction'},
                'car-index' => $car->{'carIndex'} };
            
            $ifParam->{'interface-name'} =
                $interface->{$data->{'nameref'}{'ifReferenceName'}};
            $ifParam->{'interface-nick'} =
                $interface->{$data->{'nameref'}{'ifNick'}};
            $ifParam->{'node-display-name'} =
                $interface->{$data->{'nameref'}{'ifReferenceName'}};
            
            if( defined($data->{'nameref'}{'ifComment'}) and
                defined($interface->{$data->{'nameref'}{'ifComment'}}) )
            {
                $ifParam->{'comment'} =
                    $interface->{$data->{'nameref'}{'ifComment'}};
            }

            my $legend = sprintf("Type: %s;", $car->{'configType'});
            if( $car->{'accIdx'} > 0 )
            {
                $legend .= sprintf("Access list: %d;", $car->{'accIdx'});
            }

            if( defined($car->{'rate'}) )
            {
                $legend .= sprintf('Rate: %d bps;', $car->{'rate'});
            }
            
            if( defined($car->{'limit'}) )
            {
                $legend .= sprintf('Limit: %d bytes;', $car->{'limit'});
            }

            if( defined($car->{'extLimit'}) )
            {
                $legend .= sprintf('Ext limit: %d bytes;', $car->{'extLimit'});
            }

            if( defined($car->{'conformAction'}) )
            {
                $legend .= sprintf('Conform action: %s;',
                                   $car->{'conformAction'});
            }

            if( defined($car->{'exceedAction'}) )
            {
                $legend .= sprintf('Exceed action: %s',
                                   $car->{'exceedAction'});
            }

            $ifParam->{'legend'} = $legend;

            $cb->addSubtree
                ( $countersNode,
                  $subtreeName,
                  $ifParam, 
                  ['CiscoIOS::cisco-car']);
        }
    }


    if( $devdetails->hasCap('ciscoVPDN') )
    { 
        my $tunnelNode = $cb->addSubtree
            ( $devNode, 'VPDN_Statistics',
              {'node-display-name' => 'VPDN Statistics',
               'comment' => 'VPDN tunnel and session counters'},
              [ 'CiscoIOS::cisco-vpdn-subtree' ] );

        foreach my $INDEX ( sort keys %{$data->{'ciscoVPDN'}} )
        {
            my $tunnelProtocol = $data->{'ciscoVPDN'}{$INDEX};

            $cb->addSubtree( $tunnelNode, $tunnelProtocol,
                             { 'comment'  => $tunnelProtocol . ' information',
                               'tunIndex' => $INDEX,
                               'tunFile'  => lc($tunnelProtocol) },
                             [ 'CiscoIOS::cisco-vpdn-leaf' ] );
        }
    }

    if( $devdetails->hasCap('Cisco3G') )
    { 
        foreach my $phy ( sort keys %{$data->{'cisco3G'}} )
        {
            my @templates;
            my $summary_leaf;
            if( $data->{'cisco3G'}{$phy}{'standard'} eq 'gsm' )
            {
                push(@templates, 'CiscoIOS::cisco-3g-gsm-stats');
                $summary_leaf = 'RSSI';
            }
            
            my $phyName = $data->{'cisco3G'}{$phy}{'name'};

            my $subtreeName = $phyName;
            $subtreeName =~ s/\W/_/go;
            
            my $subtree = $cb->addSubtree
                ( $devNode, $subtreeName,
                  {
                      'node-display-name' => $phyName,
                      'comment'  => '3G cellular statistics',
                      'cisco-3g-phy' => $phy,
                      'cisco-3g-phyname' => $phyName,
                      '3gcell-nodeid' => 'cell//%nodeid-device%//' . $phy,
                      'nodeid' => '%3gcell-nodeid%',
                  },
                  \@templates );
            
            if( defined($data->{'cisco3G_tokenset'}) )
            {
                $cb->addLeaf
                    ($subtree, $summary_leaf,
                     {'tokenset-member' => $data->{'cisco3G_tokenset'}});
            }
        }
    }

    if( $devdetails->hasCap('CiscoPortQos') )
    {
        my $subtreeNode = $cb->addSubtree
            ( $devNode, 'Port_QoS',
              {'node-display-name' => 'QoS drop statistics'} );

        my $precedence = 1000;
        foreach my $qos_entry (sort keys %{$data->{'ciscoPortQos'}})
        {
            my $entry = $data->{'ciscoPortQos'}{$qos_entry};
            
            my $interface = $data->{'interfaces'}{$entry->{'ifIndex'}};
            next unless defined($interface);
            next if $interface->{'excluded'};

            my $leafName =
                $interface->{$data->{'nameref'}{'ifSubtreeName'}} . '_' .
                $entry->{'direction'} . '_drops';

            my $intfName  =
                $interface->{$data->{'nameref'}{'ifReferenceName'}};

            my $intfNick = $interface->{$data->{'nameref'}{'ifNick'}};

            my $params = {
                'cisco-pqos-entry' => $qos_entry,
                'cisco-pqos-ifnick' => $intfNick,
                'cisco-pqos-direction' => $entry->{'direction'},
                'graph-legend' => 'Dropped packets',
                'precedence' => $precedence--,                
            };

            $params->{'node-display-name'} =
                $intfName . ' ' . $entry->{'direction'} . ' drops';
            
            $params->{'graph-title'} =
                $params->{'descriptive-nickname'} = 
                '%system-id% ' . $intfName . ' ' .
                $entry->{'direction'} . ' drops';
            
            $cb->addLeaf($subtreeNode, $leafName, $params,
                ['CiscoIOS::cisco-port-qos-packets']);
        }
    }

    return;
}




1;


# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 4
# End:
