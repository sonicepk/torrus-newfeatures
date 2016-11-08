# Torrus Device Discovery Site config. Put all your site specifics here.
$Torrus::DevDiscover::datadir = '/var/torrus/collector_rrd';
push(@Torrus::DevDiscover::loadModules, 'Torrus::DevDiscover::Juniper_IFOPTICS_MIB');
$Torrus::SQL::connections{'Default'}{'dsn'} = 'DBI:mysql:database=torrus;host=localhost';
$Torrus::ConfigBuilder::templateRegistry{'Juniper_IFOPTICS_MIB::dwdm-subtree'} = {'name' => 'dwdm-subtree','source' => 'vendor/juniper.dwdm.xml'};
$Torrus::ConfigBuilder::templateRegistry{'Juniper_IFOPTICS_MIB::dwdm-interface'} = {'name' => 'dwdm-interface','source' => 'vendor/juniper.dwdm.xml'};
1;
