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

# This module is tested with DWDM cards in Juniper MX960/MX480/MX240 routers.
# The Juniper MIB is called. jnxIfOpticsMib

# By default, Juniper_IFOPTICS_MIB stats are not discovered.
# These counters are only present in Juniper 100GE DWDM interfaces. 
# Enable graphing of these counters in your discovery file.
# <param name="Juniper_IFOPTICS_MIB::dwdm-stats" value="yes"/>

package Torrus::DevDiscover::Juniper_IFOPTICS_MIB;

use strict;
use warnings;

use Torrus::Log;
use Data::Dumper;

$Torrus::DevDiscover::registry{'Juniper_IFOPTICS_MIB'} = {
    'sequence'     => 600,
    'checkdevtype' => \&checkdevtype,
    'discover'     => \&discover,
    'buildConfig'  => \&buildConfig
    };

our %oiddef =
    (
     #Juniper jnxIfOpticsMIB ie Juniper_IFOPTICS_MIB
    'jnxOpticsPMCurrentEntry'           => '1.3.6.1.4.1.2636.3.71.1.2.1.1',
    'jnxPMCurChromaticDispersion'       => '1.3.6.1.4.1.2636.3.71.1.2.1.1.1',
    'jnxPMCurDiffGroupDelay'            => '1.3.6.1.4.1.2636.3.71.1.2.1.1.2',
    'jnxPMCurPolarizationState'         => '1.3.6.1.4.1.2636.3.71.1.2.1.1.3',
    'jnxPMCurPolarDepLoss'              => '1.3.6.1.4.1.2636.3.71.1.2.1.1.4',
    'jnxPMCurQ'                         => '1.3.6.1.4.1.2636.3.71.1.2.1.1.5',
    'jnxPMCurSNR'                       => '1.3.6.1.4.1.2636.3.71.1.2.1.1.6',
    'jnxPMCurTxOutputPower'             => '1.3.6.1.4.1.2636.3.71.1.2.1.1.7',
    'jnxPMCurRxInputPower'              => '1.3.6.1.4.1.2636.3.71.1.2.1.1.8',
    'jnxPMCurMinChromaticDispersion'    => '1.3.6.1.4.1.2636.3.71.1.2.1.1.9',
    'jnxPMCurTxLaserBiasCurrent'        => '1.3.6.1.4.1.2636.3.71.1.2.1.1.35',
    'jnxPMCurTemperature'               => '1.3.6.1.4.1.2636.3.71.1.2.1.1.39',
    'jnxPMCurCarFreqOffset'             => '1.3.6.1.4.1.2636.3.71.1.2.1.1.43',
    'jnxPMCurRxLaserBiasCurrent'        => '1.3.6.1.4.1.2636.3.71.1.2.1.1.47',
    );

sub checkdevtype
{
    my $dd = shift;
    my $devdetails = shift;

    my $data = $devdetails->data();
    my $matched = 0;

    if( $devdetails->paramEnabled('Juniper_IFOPTICS_MIB::dwdm-stats') and
        $dd->checkSnmpTable('jnxOpticsPMCurrentEntry') )
    {
        $matched = 1;
        $devdetails->setCap('jnxOpticsPMCurrentEntry');
    }
	#print "matched = $matched\n";
    return $matched;
}


sub discover
{
    my $dd = shift;
    my $devdetails = shift;

    my $data = $devdetails->data();
    my $session = $dd->session();

        if( $devdetails->hasCap('jnxOpticsPMCurrentEntry') )
        {
            my $ifStats = $dd->walkSnmpTable('jnxPMCurSNR');
            foreach my $ifIndex (keys %{$ifStats})
            {
                my $interface = $data->{'interfaces'}{$ifIndex};
        		next if not defined($interface);
                next if $interface->{'excluded'};

               $data->{'dwdm'}{$ifIndex} = 1;
            }
	       #print Dumper($data->{'dwdm'});
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

        my $subtreeName = 'dwdm';

        my $subtreeParam = {
            'precedence'          => '600',
            'node-display-name'   => 'DWDM  Statistics',
            'comment'        => 'DWDM interface statistics ',
        };

        my $subtreeNode =
            $cb->addSubtree( $devNode, $subtreeName, $subtreeParam,
                             ['Juniper_IFOPTICS_MIB::dwdm-subtree']);

        my $precedence = 1000;
        foreach my $ifIndex ( sort {$a<=>$b} %{$data->{'dwdm'}} )
        {
            my $interface = $data->{'interfaces'}{$ifIndex};
            next if not defined($interface);
            next if $interface->{'excluded'};

            my $ifSubtreeName =
                $interface->{$data->{'nameref'}{'ifSubtreeName'}};

           $interface->{'param'}{'devdiscover-nodetype'} =
           'Juniper_IFOPTICS_MIB::jnxOpticsPMCurrentEntry';

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
            
            $ifParam->{'nodeid-interface-chromatic-dispersion'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//Chromatic';

            $ifParam->{'nodeid-interface-diff-delay'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//DiffDelay';
            
            $ifParam->{'nodeid-interface-temp'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//temp';
            
            $ifParam->{'nodeid-interface-snr'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//CurSNR';
            
            $ifParam->{'nodeid-interface-curq'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//CurQ';
            
            $ifParam->{'nodeid-interface-tx-power'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//TxOutputPower';
            
            $ifParam->{'nodeid-interface-rx-power'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//RxInputPower';
            
            $ifParam->{'nodeid-interface-laser-rx-bias'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//LaserRxBias';
            
            $ifParam->{'nodeid-interface-laser-tx-bias'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//LaserTxBias';
            
            $ifParam->{'interface-index'} = $ifIndex;

            if( defined($data->{'nameref'}{'ifComment'}) and
                defined($interface->{$data->{'nameref'}{'ifComment'}}) )
            {
                $ifParam->{'comment'} =
                    $interface->{$data->{'nameref'}{'ifComment'}};
            }

            my $templates = ['Juniper_IFOPTICS_MIB::dwdm-interface'];

	    if( scalar(@{$templates}) > 0 )
            {
                my $intfNode = $cb->addSubtree( $subtreeNode, $ifSubtreeName,
                                                $ifParam, $templates );

            }

        }

    return;
}


# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 4
# End:

