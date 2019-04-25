#  Copyright (C) 2013 Stanislav Sinyagin
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
#  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

# Albis Technologies ULAF ACCEED devices

package Torrus::DevDiscover::Albis_ULAF;

use strict;
use warnings;

use Torrus::Log;
use Data::Dumper;

$Torrus::DevDiscover::registry{'Albis_ULAF'} = {
    'sequence'     => 500,
    'checkdevtype' => \&checkdevtype,
    'discover'     => \&discover,
    'buildConfig'  => \&buildConfig
    };


our %oiddef =    
    (
     'ulafProducts'     => '1.3.6.1.4.1.1887.1.2',
     # ACCEED-MIB
     'acceedInvDeviceUserDescr' => '1.3.6.1.4.1.1887.1.3.1.1.1.1.9',
     'acceedSoamMpDescr'        => '1.3.6.1.4.1.1887.1.3.1.4.1.1.3',
     'acceedSoamMpMaintenanceDomainName' => '1.3.6.1.4.1.1887.1.3.1.4.1.1.5',
     'acceedSoamMpShortMaName'  => '1.3.6.1.4.1.1887.1.3.1.4.1.1.7',
     
     # LM measurement configuration
     'acceedSoamLmCfgType' => '1.3.6.1.4.1.1887.1.3.1.4.11.1.2',
     'acceedSoamLmCfgEnabled' => '1.3.6.1.4.1.1887.1.3.1.4.11.1.4',
     'acceedSoamLmCfgMessagePeriod' => '1.3.6.1.4.1.1887.1.3.1.4.11.1.6',
     'acceedSoamLmCfgMeasurementInterval' =>
     '1.3.6.1.4.1.1887.1.3.1.4.11.1.12',
     'acceedSoamLmCfgAvailabilityMeasurementInterval' =>
     '1.3.6.1.4.1.1887.1.3.1.4.11.1.26',
     'acceedSoamLmCfgMpDomain' => '1.3.6.1.4.1.1887.1.3.1.4.11.1.101',
     'acceedSoamLmCfgMpPoint' => '1.3.6.1.4.1.1887.1.3.1.4.11.1.102',
     'acceedSoamLmCurrentAvailStatsForwardAvailable' =>
     '1.3.6.1.4.1.1887.1.3.1.4.13.1.9',
     
     # DM measurement configuration
     'acceedSoamDmCfgEnabled' => '1.3.6.1.4.1.1887.1.3.1.4.21.1.4',
     'acceedSoamDmCfgMessagePeriod' => '1.3.6.1.4.1.1887.1.3.1.4.21.1.6',
     'acceedSoamDmCfgMeasurementInterval' =>
     '1.3.6.1.4.1.1887.1.3.1.4.21.1.12',
     'acceedSoamDmCfgMpDomain' => '1.3.6.1.4.1.1887.1.3.1.4.21.1.101',
     'acceedSoamDmCfgMpPoint' => '1.3.6.1.4.1.1887.1.3.1.4.21.1.102',     
     );


# acceedSoamLmCfgType values
my $lmTypeDef = {
    '1' => 'LMM',
    '2' => 'SLM',
    '3' => 'CCM'
    };

sub checkdevtype
{
    my $dd = shift;
    my $devdetails = shift;

    if( not $dd->oidBaseMatch
        ( 'ulafProducts',
          $devdetails->snmpVar( $dd->oiddef('sysObjectID') ) ) )
    {
        return 0;
    }
    
    $devdetails->setCap('interfaceIndexingPersistent');
    
    return 1;
}


sub discover
{
    my $dd = shift;
    my $devdetails = shift;

    my $data = $devdetails->data();
    my $session = $dd->session();

    # Versions 2.00 and 2.10 do not support more then one OID on some requests
    my $oids_per_pdu = 10;
    my $sysdescr = $devdetails->snmpVar($dd->oiddef('sysDescr'));
    if( $sysdescr =~ / V2.(1|0)0,/o )
    {
        $oids_per_pdu = 1;
    }
    
    $data->{'param'}{'snmp-oids-per-pdu'} = $oids_per_pdu;

    # work around missing entPhysicalContainedIn
    if( not defined($data->{'param'}{'comment'}) and
        defined($data->{'entityPhysical'}{'1'}) and
        defined($data->{'entityPhysical'}{'1'}{'descr'}) )
    {
        $data->{'param'}{'comment'} =
            $data->{'entityPhysical'}{'1'}{'descr'};
    }

    # device descriptions
    # INDEX { devicePortIndex,
    #         deviceLinkIndex,
    #         entPhysicalIndex }

    my $devDescr = $dd->walkSnmpTable('acceedInvDeviceUserDescr');
    foreach my $idx (keys %{$devDescr})
    {
        if( $devDescr->{$idx} eq '' )
        {
            $devDescr->{$idx} = $idx;
        }
    }
    
    # maintenance point descriptions
    # INDEX { devicePortIndex,
    #         deviceLinkIndex,
    #         entPhysicalIndex,
    #         acceedSoamMpDomainIndex,
    #         acceedSoamMpPointIndex }
    
    my $acceedSoamMpDescr = $dd->walkSnmpTable('acceedSoamMpDescr');
    my $acceedSoamMpShortMaName =
        $dd->walkSnmpTable('acceedSoamMpShortMaName');

    my $getMPDescr = sub
    {
        my $index = shift;
        my $descr = $acceedSoamMpShortMaName->{$index};
        if( not defined($descr) or $descr eq '' )
        {
            $descr = $acceedSoamMpDescr->{$index};
        }
        
        if( not defined($descr) or $descr eq '' )
        {
            $descr = $index;
        }
        return($descr);
    };

    # filter by MP name
    my $mp_name_filter = $devdetails->param('Albis_ULAF::mp-name-filter');
    
    {
    # LM test configurations
    # INDEX { devicePortIndex,
    #         deviceLinkIndex,
    #         entPhysicalIndex,
    #         acceedSoamLmCfgIndex }

        my $lmcfg = {};
        foreach my $oidname
            (
             'acceedSoamLmCfgType',
             'acceedSoamLmCfgEnabled',
             'acceedSoamLmCfgMessagePeriod',
             'acceedSoamLmCfgMeasurementInterval',
             'acceedSoamLmCfgAvailabilityMeasurementInterval',
             'acceedSoamLmCfgMpDomain',
             'acceedSoamLmCfgMpPoint',
             'acceedSoamLmCurrentAvailStatsForwardAvailable'
             )
        {
            $lmcfg->{$oidname} = $dd->walkSnmpTable($oidname);
        }

        foreach my $idx (keys %{$lmcfg->{'acceedSoamLmCfgEnabled'}})
        {
            if( $lmcfg->{'acceedSoamLmCfgEnabled'}{$idx} == 1 )
            {
                if( not defined
                    $lmcfg->{'acceedSoamLmCurrentAvailStatsForwardAvailable'}{
                        $idx} )
                {
                    Warn('LM measurement ' . $idx .
                         ' does not have availability data');
                    next;
                }

                my $ref = {};

                my @x = split(/\./, $idx);
                my $devIdx = join('.', $x[0], $x[1], $x[2]);
                my $cfgIdx = $x[3];
                
                $ref->{'devDescr'} = $devDescr->{$devIdx};
                $ref->{'lmType'} = $lmTypeDef->{
                    $lmcfg->{'acceedSoamLmCfgType'}{$idx}};
                
                $ref->{'period'} =
                    $lmcfg->{'acceedSoamLmCfgMessagePeriod'}{$idx};
                $ref->{'interval'} =
                    $lmcfg->{'acceedSoamLmCfgMeasurementInterval'}{$idx};
                $ref->{'availInterval'} =
                    $lmcfg->{'acceedSoamLmCfgAvailabilityMeasurementInterval'}{
                        $idx};

                my $domain = $lmcfg->{'acceedSoamLmCfgMpDomain'}{$idx};
                my $point = $lmcfg->{'acceedSoamLmCfgMpPoint'}{$idx};

                $ref->{'mpDescr'} =
                    &{$getMPDescr}($devIdx . '.' . $domain . '.' . $point);
                
                $ref->{'nodeid-prefix'} =
                    'soam//%nodeid-device%' . '//' . $idx;

                if( defined($mp_name_filter) and
                    $ref->{'mpDescr'} =~ $mp_name_filter )
                {
                    next;
                }

                $data->{'acceedSoamLm'}{$idx} = $ref;
            }
        }

        my $nLMmeasurements = scalar(keys %{$data->{'acceedSoamLm'}});
        Debug('Found ' . $nLMmeasurements . ' SOAM LM measurements');
        if( $nLMmeasurements > 0 )
        {
            $devdetails->setCap('acceedSoamLm');
        }
    }

    {
        # DM test configurations
        # INDEX { devicePortIndex,
        #         deviceLinkIndex,
        #         entPhysicalIndex,
        #         acceedSoamDmCfgIndex }

        my $dmcfg = {};
        foreach my $oidname
            (
             'acceedSoamDmCfgEnabled',
             'acceedSoamDmCfgMessagePeriod',
             'acceedSoamDmCfgMeasurementInterval',
             'acceedSoamDmCfgMpDomain',
             'acceedSoamDmCfgMpPoint',
             )
        {
            $dmcfg->{$oidname} = $dd->walkSnmpTable($oidname);
        }

        foreach my $idx (keys %{$dmcfg->{'acceedSoamDmCfgEnabled'}})
        {
            if( $dmcfg->{'acceedSoamDmCfgEnabled'}{$idx} == 1 )
            {
                my $ref = {};

                my @x = split(/\./, $idx);
                my $devIdx = join('.', $x[0], $x[1], $x[2]);
                my $cfgIdx = $x[3];
                
                $ref->{'devDescr'} = $devDescr->{$devIdx};

                $ref->{'period'} =
                    $dmcfg->{'acceedSoamDmCfgMessagePeriod'}{$idx};
                $ref->{'interval'} =
                    $dmcfg->{'acceedSoamDmCfgMeasurementInterval'}{$idx};

                my $domain = $dmcfg->{'acceedSoamDmCfgMpDomain'}{$idx};
                my $point = $dmcfg->{'acceedSoamDmCfgMpPoint'}{$idx};

                $ref->{'mpDescr'} =
                    &{$getMPDescr}($devIdx . '.' . $domain . '.' . $point);

                $ref->{'nodeid-prefix'} =
                    'soam//%nodeid-device%' . '//' . $idx;

                if( defined($mp_name_filter) and
                    $ref->{'mpDescr'} =~ $mp_name_filter )
                {
                    next;
                }
                
                $data->{'acceedSoamDm'}{$idx} = $ref;
            }
        }
        
        my $nDMmeasurements = scalar(keys %{$data->{'acceedSoamDm'}});
        Debug('Found ' . $nDMmeasurements . ' SOAM DM measurements');
        if( $nDMmeasurements > 0 )
        {
            $devdetails->setCap('acceedSoamDm');
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
    
    if( $devdetails->hasCap('acceedSoamLm') )
    {
        my $lmNodeParam = {
            'comment' => 'SOAM Frame Loss Measurement statistics',
            'node-display-name' => 'SOAM LM',
        };
        
        my $lmNode =
            $cb->addSubtree( $devNode, 'SOAM-LM', $lmNodeParam,
                             ['Albis_ULAF::albis-soam-lm-subtree'] );
        
        foreach my $idx (sort keys %{$data->{'acceedSoamLm'}})
        {
            my $ref = $data->{'acceedSoamLm'}{$idx};
            my $legend =
                'Maintenance Point:' . $ref->{'mpDescr'} . ';' .
                'Measurement interval:' .
                $ref->{'interval'} . ' minutes;' .
                'Availability measurement interval: ' .
                $ref->{'availInterval'} . ' minutes;' .
                'Period:' . $ref->{'period'} . ' ms;' .
                'Loss Management type: ' .
                $ref->{'lmType'} . ';' .
                'Device: ' . $ref->{'devDescr'};

            my $gtitle = $ref->{'devDescr'} . ', ' . $ref->{'mpDescr'};

            my $nodeid = $ref->{'nodeid-prefix'} . '//lm';
            
            my $param = {
                'acceed-soam-cfg-index' => $idx,
                'rrd-create-max' => ($ref->{'period'} * 1.5 / 1000),
                'node-display-name' => $ref->{'mpDescr'},
                'acceed-mp-description' => $ref->{'mpDescr'},
                'acceed-soam-nodeid' => $nodeid,
                'nodeid' => $nodeid,
                'legend' => $legend,
                'graph-title' => $gtitle,
            };

            my $subtreeName = $idx;
            
            $cb->addSubtree( $lmNode, $subtreeName, $param,
                             ['Albis_ULAF::albis-soam-lm']);
        }
    }


    if( $devdetails->hasCap('acceedSoamDm') )
    {
        my $dmNodeParam = {
            'comment' => 'SOAM Frame Delay Measurement statistics',
            'node-display-name' => 'SOAM DM',
        };
        
        my $dmNode =
            $cb->addSubtree( $devNode, 'SOAM-DM', $dmNodeParam,
                             ['Albis_ULAF::albis-soam-dm-subtree']);
        
        foreach my $idx (sort keys %{$data->{'acceedSoamDm'}})
        {
            my $ref = $data->{'acceedSoamDm'}{$idx};
            my $legend =
                'Maintenance Point:' . $ref->{'mpDescr'} . ';' .
                'Measurement interval:' .
                $ref->{'interval'} . ' minutes;' .
                'Period:' . $ref->{'period'} . ' ms;' .
                'Device: ' . $ref->{'devDescr'};

            my $gtitle = $ref->{'devDescr'} . ', ' . $ref->{'mpDescr'};

            my $nodeid = $ref->{'nodeid-prefix'} . '//dm';
            
            my $param = {
                'acceed-soam-cfg-index' => $idx,
                'node-display-name' => $ref->{'mpDescr'},
                'acceed-mp-description' => $ref->{'mpDescr'},
                'acceed-soam-nodeid' => $nodeid,
                'nodeid' => $nodeid,
                'legend' => $legend,                
                'graph-title' => $gtitle,
            };

            my $subtreeName = $idx;
            
            $cb->addSubtree( $dmNode, $subtreeName, $param,
                             ['Albis_ULAF::albis-soam-dm']);
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
