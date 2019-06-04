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
# The Juniper MIB is called. JNX-OPT-IF-EXT-MIB 

# By default, Juniper_JNX-OPT-IF-EXT-MIB stats are not discovered.
# These counters are only present in Juniper 100GE DWDM interfaces. 
# Enable graphing of these counters in your discovery file.
# <param name="Juniper_OPT_IF_EXT_MIB::dwdm-stats" value="yes"/>

package Torrus::DevDiscover::Juniper_OPT_IF_EXT_MIB;

use strict;
use warnings;

use Torrus::Log;
use Data::Dumper;

$Torrus::DevDiscover::registry{'Juniper_OPT_IF_EXT_MIB'} = {
    'sequence'     => 600,
    'checkdevtype' => \&checkdevtype,
    'discover'     => \&discover,
    'buildConfig'  => \&buildConfig
    };

our %oiddef =
    (
     #Juniper jnxIfOpticsMIB ie Juniper_OPT_IF_EXT_MIB
    'jnxoptIfOTNPMFECCurrentEntry'              => '1.3.6.1.4.1.2636.3.73.1.3.3.8.1',
    'jnxoptIfOTNPMCurrentFECCorrectedErr'       => '1.3.6.1.4.1.2636.3.73.1.3.3.8.1.3',
    'jnxoptIfOTNPMCurrentFECUncorrectedWords'   => '1.3.6.1.4.1.2636.3.73.1.3.3.8.1.4',
    'jnxoptIfOTNPMCurrentFECBERMantissa'        => '1.3.6.1.4.1.2636.3.73.1.3.3.8.1.5',
    'jnxoptIfOTNPMCurrentFECBERExponent'        => '1.3.6.1.4.1.2636.3.73.1.3.3.8.1.6',
    );

sub checkdevtype
{
    my $dd = shift;
    my $devdetails = shift;

    my $data = $devdetails->data();
    my $matched = 0;

    if( $devdetails->paramEnabled('Juniper_OPT_IF_EXT_MIB::dwdm-stats') and
        $dd->checkSnmpTable('jnxoptIfOTNPMFECCurrentEntry') )
    {
        $matched = 1;
        $devdetails->setCap('jnxoptIfOTNPMFECCurrentEntry');
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

        if( $devdetails->hasCap('jnxoptIfOTNPMFECCurrentEntry') )
        {
            my $ifStats = $dd->walkSnmpTable('jnxoptIfOTNPMCurrentFECCorrectedErr');

            foreach my $ifIndex (keys %{$ifStats})
            {
            $ifIndex =~ m/(\d+)/;
                my $interface = $data->{'interfaces'}{$1};
        		next if not defined($interface);
                next if $interface->{'excluded'};

               $data->{'dwdmfec'}{$1} = 1;
            }
	       #print "dwdmfec dump", Dumper($data->{'dwdmfec'});
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

        my $subtreeName = 'dwdmfec';

        my $subtreeParam = {
            'precedence'          => '-600',
            'node-display-name'   => 'DWDM FEC Statistics',
            'comment'        => 'DWDM FEC interface statistics ',
        };

        my $subtreeNode =
            $cb->addSubtree( $devNode, $subtreeName, $subtreeParam,
                             ['Juniper_OPT_IF_EXT_MIB::dwdmfec-subtree']);

        my $precedence = 1000;
        foreach my $ifIndex ( sort {$a<=>$b} %{$data->{'dwdmfec'}} )
        {
            my $interface = $data->{'interfaces'}{$ifIndex};
            next if not defined($interface);
            next if $interface->{'excluded'};

            my $ifSubtreeName =
                $interface->{$data->{'nameref'}{'ifSubtreeName'}};

           $interface->{'param'}{'devdiscover-nodetype'} =
           'Juniper_OPT_IF_EXT_MIB::jnxoptIfOTNPMFECCurrentEntry';

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
            
            $ifParam->{'nodeid-interface-fec-corrected'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//FECCorrected';

            $ifParam->{'nodeid-interface-fec-uncorrected'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//FECUNCorrected';
            
            $ifParam->{'nodeid-fec-mantissa'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//FECMan';
            
            $ifParam->{'nodeid-fec-exponent'} =
                $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
                $interface->{$data->{'nameref'}{'ifNodeid'}} . '//FECExponent';

	       #print Dumper($data->{$ifParam});
            
            #$ifParam->{'nodeid-fec-rate'} =
            #    $interface->{$data->{'nameref'}{'ifNodeidPrefix'}} .
            #    $interface->{$data->{'nameref'}{'ifNodeid'}} . '//FECRate';
            
            $ifParam->{'interface-index'} = $ifIndex;
            $ifParam->{'nearEnd'} = "1";
            
            if( defined($data->{'nameref'}{'ifComment'}) and
                defined($interface->{$data->{'nameref'}{'ifComment'}}) )
            {
                $ifParam->{'comment'} =
                    $interface->{$data->{'nameref'}{'ifComment'}};
        
            }

        my $templates = ['Juniper_OPT_IF_EXT_MIB::dwdmfec-interface'];

	    if( scalar(@{$templates}) > 0 )
            {
                my $intfNode = $cb->addSubtree( $subtreeNode, $ifSubtreeName,
                                                $ifParam, $templates);

            }
                                            
        }

    return;
}


# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 4
# End:

