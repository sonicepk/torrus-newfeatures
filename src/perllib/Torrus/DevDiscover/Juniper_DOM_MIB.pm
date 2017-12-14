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

# Eoin Kenny <eoinpk.ek@gmail.com>

# This module requires testing. 
# This table jnxDomCurrentEntry is buried inside JUNIPER-DOM-MIB. Also as the ACX
# series does not support DOM via SNMP the only way to get the DOM values is via
# a script on the box and the Juniper utility MIB.  jnxUtilStringValue

# By default, Juniper_DOM_MIB stats are not discovered.
# These counters are only present in optics that support digital optical monitoring. 
# Typically most new single mode SFP/SFP+/XFP/QSFP etc will support DOM. 
# Enable graphing of these counters in your discovery file.
# <param name="Juniper_DOM_MIB::dom-stats" value="yes"/>

package Torrus::DevDiscover::Juniper_DOM_MIB;

use strict;
use warnings;

use Torrus::Log;
use Data::Dumper;

$Torrus::DevDiscover::registry{'Juniper_DOM_MIB'} = {
    'sequence'     => 600,
    'checkdevtype' => \&checkdevtype,
    'discover'     => \&discover,
    'buildConfig'  => \&buildConfig
    };

our %oiddef =
    (
     #Juniper jnxDomCurrentEntry 
    'jnxDomCurrentEntry'                    => '1.3.6.1.4.1.2636.3.60.1.1.1.1',
    'jnxDomCurrentRxLaserPower'             => '1.3.6.1.4.1.2636.3.60.1.1.1.1.5',
    'jnxDomCurrentTxLaserOutputPower'       => '1.3.6.1.4.1.2636.3.60.1.1.1.1.7',
    'jnxUtilStringValue'                    => '1.3.6.1.4.1.2636.3.47.1.1.5.1.2',
    'rx_power'                              => '1.3.6.1.4.1.2636.3.47.1.1.5.1.2.111.112.116.105.99.115.78',
    'jnxDomLaneIndex'                       => '1.3.6.1.4.1.2636.3.60.1.2.1.1.1',
    'jnxDomCurrentLaneRxLaserPower'         => '1.3.6.1.4.1.2636.3.60.1.2.1.1.6',
    'jnxDomCurrentLaneTxLaserOutputPower'   => '1.3.6.1.4.1.2636.3.60.1.2.1.1.8',
    );

sub checkdevtype
{
    my $dd = shift;
    my $devdetails = shift;

    my $data = $devdetails->data();
    my $matched = 0;

    if( $devdetails->paramEnabled('Juniper_DOM_MIB::dom-stats') and
        $dd->checkSnmpTable('jnxDomCurrentEntry') )
    {
        $matched = 1;
        $devdetails->setCap('jnxDomCurrentEntry');
	    #print "matched dom = $matched\n";
    }
    if( $devdetails->paramEnabled('Juniper_DOM_MIB::dom-stats') and
        $dd->checkSnmpTable('rx_power') and
        !$dd->checkSnmpTable('jnxDomCurrentEntry')))
    {
        $matched = 1;
        $devdetails->setCap('acx_dom');
	    #print "matched acx = $matched\n";
    }
    if( $devdetails->paramEnabled('Juniper_DOM_MIB::dom-stats') and
        $dd->checkSnmpTable('jnxDomLaneIndex') )
    {
        $matched = 1;
        $devdetails->setCap('jnxDomLane');
	    #print "matched jnxDomLane = $matched\n";
    }

    return $matched;
}


sub discover
{
    my $dd = shift;
    my $devdetails = shift;

    my $data = $devdetails->data();
    my $session = $dd->session();

        if( $devdetails->hasCap('jnxDomCurrentEntry') )
        {
            my $ifStats = $dd->walkSnmpTable('jnxDomCurrentRxLaserPower');
            foreach my $ifIndex (keys %{$ifStats})
            {
                my $interface = $data->{'interfaces'}{$ifIndex};
        		next if not defined($interface);
                next if $interface->{'excluded'};

               $data->{'dom'}{$ifIndex} = 1;
            }
        }

        if( $devdetails->hasCap('acx_dom') )
        {
            my $ifStats = $dd->walkSnmpTable('rx_power');
            #print "my ifstats", Dumper($ifStats);
            foreach my $NewifIndex (keys %{$ifStats})
            {
            my $ifIndex = "";

                foreach my $char (split (/\./, $NewifIndex)) {
                    $ifIndex = $ifIndex.chr($char);
                    }
                    #print "Actual Index\n", $ifIndex;
                
                my $interface = $data->{'interfaces'}{$ifIndex};
         		next if not defined($interface);
                next if $interface->{'excluded'};

               $data->{'acxdom'}{$ifIndex} = 1;
            }
        }
        #try and find the 100Ge LR - 4 lane optics only.
        if( $devdetails->hasCap('jnxDomLane') )
        {
            my $ifStats = $dd->walkSnmpTable('jnxDomLaneIndex');
            foreach my $NewifIndex (keys %{$ifStats})
            {
                if( $ifStats->{$NewifIndex} == 1)
                {   
                #Found an ifIndex with a 100Ge LR port as has a lane port with id 1. 
                $NewifIndex =~ m/(\d+)/;
                
                my $interface = $data->{'interfaces'}{$1};
         		next if not defined($interface);
                next if $interface->{'excluded'};
                
                $data->{'jnxDomLane'}{$1} = 1;
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

    my $data = $devdetails->data();
        #print "Dump of all $data", Dumper($data);

        my $subtreeName = 'dom';

        my $subtreeParam = {
            'precedence'          => '-600',
            'node-display-name'   => 'Digital Optical Monitoring Statistics',
            'comment'        => 'DOM interface statistics ',
        };

        my $subtreeNode =
            $cb->addSubtree( $devNode, $subtreeName, $subtreeParam,
                             ['Juniper_DOM_MIB::dom-subtree']);

        my $precedence = 1000;
        if ($data->{'dom'}){
        
                    foreach my $ifIndex ( sort {$a<=>$b} %{$data->{'dom'}} )
                    {
                    my $interface = $data->{'interfaces'}{$ifIndex};
                        next if not defined($interface);
                        next if $interface->{'excluded'};

                    my $ifSubtreeName =
                        $interface->{$data->{'nameref'}{'ifSubtreeName'}};

                   $interface->{'param'}{'devdiscover-nodetype'} =
                   'Juniper_DOM_MIB::jnxDomCurrentEntry';

                    my $ifParam = {};

                    $ifParam->{'graph-string'} =
                        '%system-id%:%interface-nick%';
                    $ifParam->{'precedence'} = $precedence;
                    
                    $ifParam->{'interface-name'} =
                        $interface->{$data->{'nameref'}{'ifReferenceName'}};
                    
                    $ifParam->{'interface-nick'} =
                        $interface->{$data->{'nameref'}{'ifNick'}};
                    
                    $ifParam->{'node-display-name'} =
                        $interface->{$data->{'nameref'}{'ifReferenceName'}};
                    
                    $ifParam->{'nodeid-interface-tx-power'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//TxLaserPower';
                    
                    $ifParam->{'nodeid-interface-rx-power'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//RxLaserPower';
                    
                    $ifParam->{'nodeid-tx-rx-power'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//tx-rx-power';
                    
                    $ifParam->{'interface-index'} = $ifIndex;

                    if( defined($data->{'nameref'}{'ifComment'}) and
                        defined($interface->{$data->{'nameref'}{'ifComment'}}) )
                    {
                        $ifParam->{'comment'} =
                            $interface->{$data->{'nameref'}{'ifComment'}};
                    }
                    my $templates = ['Juniper_DOM_MIB::dom-interface'];

                    if( scalar(@{$templates}) > 0 )
                    {
                        my $intfNode = $cb->addSubtree( $subtreeNode, $ifSubtreeName,
                                                        $ifParam, $templates );

                    }

                }
            }
        if ($data->{'acxdom'}){
        
                    foreach my $ifIndex ( sort {$a<=>$b} %{$data->{'acxdom'}} )
                    {
                    #print "inside cb acx\n", $ifIndex;
                    my $interface = $data->{'interfaces'}{$ifIndex};
                        next if not defined($interface);
                        next if $interface->{'excluded'};

                    my $ifSubtreeName =
                        $interface->{$data->{'nameref'}{'ifSubtreeName'}};

                   $interface->{'param'}{'devdiscover-nodetype'} =
                   'Juniper_DOM_MIB::jnxACXDomCurrentEntry';

                    my $ifParam = {};

                    $ifParam->{'graph-string'} =
                        '%system-id%:%interface-nick%';
                    $ifParam->{'precedence'} = $precedence;
                    
                    $ifParam->{'interface-name'} =
                        $interface->{$data->{'nameref'}{'ifReferenceName'}};
                    
                    $ifParam->{'interface-nick'} =
                        $interface->{$data->{'nameref'}{'ifNick'}};
                    
                    $ifParam->{'node-display-name'} =
                        $interface->{$data->{'nameref'}{'ifReferenceName'}};
                    
                    $ifParam->{'nodeid-interface-rx-power'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//RxLaserPower';
                   
                    my @splitlist = (split //, $ifIndex);

                    my $acxifIndex = ord($splitlist[0]) . "."  . ord($splitlist[1]) . "." . ord($splitlist[2]);

                    #print "my acxIndex = \n", $acxifIndex;

                    $ifParam->{'interface-index'} = $acxifIndex;
                    
                    $ifParam->{'nodeid-interface-tx-power'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//TxLaserPower';
                   

                    if( defined($data->{'nameref'}{'ifComment'}) and
                        defined($interface->{$data->{'nameref'}{'ifComment'}}) )
                    {
                        $ifParam->{'comment'} =
                            $interface->{$data->{'nameref'}{'ifComment'}};
                    }

                    my $templates = ['Juniper_DOM_MIB::acxdom-interface'];

                    if( scalar(@{$templates}) > 0 )
                    {
                        my $intfNode = $cb->addSubtree( $subtreeNode, $ifSubtreeName,
                                                        $ifParam, $templates );

                    }

                }
            }
        if ($data->{'jnxDomLane'}){
        

                    foreach my $ifIndex ( sort {$a<=>$b} %{$data->{'jnxDomLane'}} )
                    {
                    #print "inside cb acx\n", $ifIndex;
                    my $interface = $data->{'interfaces'}{$ifIndex};
                        next if not defined($interface);
                        next if $interface->{'excluded'};

                    my $ifSubtreeName =
                        $interface->{$data->{'nameref'}{'ifSubtreeName'}};

                   $interface->{'param'}{'devdiscover-nodetype'} =
                   'Juniper_DOM_MIB::jnxDomCurrentLaneEntry';

                    my $ifParam = {};

                    $ifParam->{'graph-string'} =
                        '%system-id%:%interface-nick%';
                    $ifParam->{'precedence'} = $precedence;
                    
                    $ifParam->{'interface-name'} =
                        $interface->{$data->{'nameref'}{'ifReferenceName'}};
                    
                    $ifParam->{'interface-nick'} =
                        $interface->{$data->{'nameref'}{'ifNick'}};
                    
                    $ifParam->{'node-display-name'} =
                        $interface->{$data->{'nameref'}{'ifReferenceName'}};
                    
                    $ifParam->{'nodeid-interface-rx-power-lane0'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//RxLaser0';
                    
                    $ifParam->{'nodeid-interface-rx-power-lane1'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//RxLaser1';
                    
                    $ifParam->{'nodeid-interface-rx-power-lane2'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//RxLaser2';
                    
                    $ifParam->{'nodeid-interface-rx-power-lane3'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//RxLaser3';
                    
                    $ifParam->{'nodeid-interface-tx-power-lane0'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//TxLaser0';
                   
                    $ifParam->{'nodeid-interface-tx-power-lane1'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//TxLaser1';
                    
                    $ifParam->{'nodeid-interface-tx-power-lane2'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//TxLaser2';
                    
                    $ifParam->{'nodeid-interface-tx-power-lane3'} =
                        $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                        $interface->{$data->{'nameref'}{'ifNodeid'}} . '//TxLaser3';
                   
                   

                    #print "my acxIndex = \n", $acxifIndex;

                    $ifParam->{'interface-index-0'} = $ifIndex . ".0";
                    $ifParam->{'interface-index-1'} = $ifIndex . ".1";
                    $ifParam->{'interface-index-2'} = $ifIndex . ".2";
                    $ifParam->{'interface-index-3'} = $ifIndex . ".3";

                    if( defined($data->{'nameref'}{'ifComment'}) and
                        defined($interface->{$data->{'nameref'}{'ifComment'}}) )
                    {
                        $ifParam->{'comment'} =
                            $interface->{$data->{'nameref'}{'ifComment'}};
                    }

                    my $templates = ['Juniper_DOM_MIB::domlane-interface'];

                    if( scalar(@{$templates}) > 0 )
                    {
                        my $intfNode = $cb->addSubtree( $subtreeNode, $ifSubtreeName,
                                                        $ifParam, $templates );

                    }

                }
            }

    return;
}


# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 4
# End:

