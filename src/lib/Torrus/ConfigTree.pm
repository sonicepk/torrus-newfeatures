#  Copyright (C) 2002-2017  Stanislav Sinyagin
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


package Torrus::ConfigTree;

use strict;
use warnings;

use Torrus::Redis;
use Git::ObjectStore;
use JSON;
use File::Path qw(make_path);
use Digest::SHA qw(sha1_hex);
use Cache::Ref::CART;

use Torrus::Log;

use Carp;

sub new
{
    my $self = {};
    my $class = shift;
    my %options = @_;
    bless $self, $class;

    my $treename = $options{'-TreeName'};
    die('ERROR: TreeName is mandatory') if not $treename;
    $self->{'treename'} = $treename;

    $self->{'iamwriter'} = $options{'-WriteAccess'} ? 1:0;

    $self->{'redis'} =
        Torrus::Redis->new(server => $Torrus::Global::redisServer);
    $self->{'redis_prefix'} = $Torrus::Global::redisPrefix;

    $self->{'json'} = JSON->new->canonical(1)->allow_nonref(1);

    $self->{'repodir'} = $Torrus::Global::gitRepoDir;

    $self->{'store_author'} = {
        'author_name'  => $Torrus::ConfigTree::writerAuthorName,
        'author_email' => $Torrus::ConfigTree::writerAuthorEmail,
    };

    $self->{'branch'} = $treename . '_configtree';
    
    my %store_args = (
        'repodir' => $self->{'repodir'},
        'branchname' => $self->{'branch'},
        );

    if( $self->{'iamwriter'} )
    {
        $store_args{'writer'} = 1;
        $self->{'gitlock'} =
            $self->{'redis_prefix'} . 'gitlock:' . $self->{'repodir'};
    }
    else
    {
        $store_args{'goto'} = $self->currentCommit();
    }
        
    $self->_lock_repodir();
    eval {
        $self->{'store'} = new Git::ObjectStore(
            %store_args, %{$self->{'store_author'}});
    };
    if( $@ )
    {
        my $msg = $@;
        $self->_unlock_repodir();
        die($msg);
    }

    $self->_unlock_repodir();
    
    
    $self->{'paramprop'} = $self->_read_json('paramprops');
    $self->{'paramprop'} = {} unless defined($self->{'paramprop'});
    
    $self->{'objcache'} = Cache::Ref::CART->new
        ( size => $Torrus::ConfigTree::objCacheSize );

    $self->{'defs'} = {};
    
    return $self;
}


sub running_writers_exist
{
    my $h = $Torrus::Global::redisPrefix . 'writer:' .
        $Torrus::Global::gitRepoDir;
    my $redis = Torrus::Redis->new(server => $Torrus::Global::redisServer);
    my $r = $redis->hgetall($h);
    if( defined($r) )
    {
        while( scalar(@{$r}) > 0 )
        {
            my $key = shift @{$r};
            my $val = shift @{$r};

            if( $val > time() - $Torrus::ConfigTree::writerTimeout )
            {
                return 1;
            }
            else
            {
                $redis->hdel($h, $key);
            }
        }
    }
    return 0;
}


sub _lock_repodir
{
    my $self = shift;

    if( $self->{'iamwriter'} )
    {
        Debug('Acquiring a lock for ' . $self->{'repodir'});
        my $timeout = time() + 15;
        while( not $self->{'redis'}->set($self->{'gitlock'}, time(),
                                         'EX', 10, 'NX')
               and time() <= $timeout )
        {
            sleep 1;
        }

        if( time() > $timeout )
        {
            die('Failed to acquire a lock for ' . $self->{'repodir'});
        }
    }

    return;
}


sub _unlock_repodir
{
    my $self = shift;

    if( $self->{'iamwriter'} )
    {
        Debug('Releasing the lock for ' . $self->{'repodir'});
        $self->{'redis'}->del($self->{'gitlock'});
    }
    return;
}


sub _sha_file
{
    my $self = shift;
    my $sha = shift;
    return join('/', substr($sha, 0, 2), substr($sha, 2, 2), substr($sha, 4));
}


sub _read_file
{
    my $self = shift;
    my $filename = shift;
    return $self->{'store'}->read_file($filename);
}


sub _read_json
{
    my $self = shift;
    my $filename = shift;

    my $blob = $self->_read_file($filename);
    if( defined($blob) )
    {
        return $self->{'json'}->decode($blob);
    }
    else
    {
        return undef;
    }
}



sub _node_read
{
    my $self = shift;
    my $token = shift;

    my $ret = $self->{'objcache'}->get($token);
    if( not defined($ret) )
    {
        my $sha_file = $self->_sha_file($token);

        $ret = $self->_read_json('nodes/' . $sha_file);
        if( not defined($ret) )
        {
            return undef;
        }

        if( $ret->{'is_subtree'} )
        {
            my $children = $self->_read_json('children/' . $sha_file);
            die('Cannot find list of children for ' . $token)
                unless defined($children);
            $ret->{'children'} = $children;
        }

        $ret->{'xparams'} = {}; #expanded params
        $ret->{'uparams'} = {}; #undefined params
        
        
        $self->{'objcache'}->set($token => $ret);
    }

    return $ret;
}


sub _other_read
{
    my $self = shift;
    my $name = shift;

    my $ret = $self->{'objcache'}->get($name);
    if( not defined($ret) )
    {
        $ret = $self->_read_json('other/' . $name);
        if( defined($ret) )
        {
            $self->{'objcache'}->set($name => $ret);
        }
    }

    return $ret;
}


sub _node_file_exists
{
    my $self = shift;
    my $token = shift;
    return $self->{'store'}->file_exists('nodes/' . $self->_sha_file($token));
}


sub currentCommit
{
    my $self = shift;
    return $self->{'redis'}->hget(
        $self->{'redis_prefix'} . 'githeads', $self->{'branch'});
}



sub treeName
{
    my $self = shift;
    return $self->{'treename'};
}



sub nodeName
{
    my $self = shift;
    my $path = shift;
    $path =~ s/.*\/([^\/]+)\/?$/$1/o;
    return $path;
}



sub token
{
    my $self = shift;
    my $path = shift;
    my $nocheck = shift;

    my $token = sha1_hex($self->{'treename'} . ':' . $path);
    if( $nocheck or $self->_node_file_exists($token) )
    {
        return $token;
    }
    else
    {
        return undef;
    }
}


sub path
{
    my $self = shift;
    my $token = shift;

    my $node = $self->_node_read($token);
    return $node->{'path'};
}


sub nodeExists
{
    my $self = shift;
    my $path = shift;

    return defined( $self->token($path) );
}


sub tokenExists
{
    my $self = shift;
    my $token = shift;

    return $self->_node_file_exists($token);
}


sub isLeaf
{
    my $self = shift;
    my $token = shift;

    my $node = $self->_node_read($token);
    return( not $node->{'is_subtree'} );
}


sub isSubtree
{
    my $self = shift;
    my $token = shift;

    my $node = $self->_node_read($token);
    return( $node->{'is_subtree'} );
}


sub isRoot
{
    my $self = shift;
    my $token = shift;

    my $node = $self->_node_read($token);
    return( $node->{'parent'} eq '');
}


sub getOtherParam
{
    my $self = shift;
    my $name = shift;
    my $param = shift;

    my $obj = $self->_other_read($name);

    if( defined($obj) )
    {
        return $obj->{'params'}{$param};
    }
    else
    {
        return undef;
    }
}


sub _read_node_param
{
    my $self = shift;
    my $token = shift;
    my $param = shift;

    my $node = $self->_node_read($token);
    if( defined($node) )
    {
        return $node->{'params'}{$param};
    }
    else
    {
        return undef;
    }
}


sub _retrieve_node_param
{
    my $self = shift;
    my $token = shift;
    my $param = shift;

    my $node = $self->{'objcache'}->get($token);
    if( defined($node) and defined($node->{'uparams'}{$param}) )
    {
        return undef;
    }
    
    my $value = $self->_read_node_param( $token, $param );
    if( not defined($value) )
    {
        my $parent = $self->getParent($token);
        if( defined($parent) )
        {
            $value = $self->_retrieve_node_param($parent, $param);
        }
    }

    if( defined($node) )
    {
        if( defined($value) )
        {
            $node->{'params'}{$param} = $value;
        }
        elsif( not $self->{'is_writing'} )
        {
            $node->{'uparams'}{$param} = 1;
        }
    }
        
    return $value;
}


sub _expand_node_param
{
    my $self = shift;
    my $token = shift;
    my $param = shift;
    my $value = shift;

    # %parameter_substitutions% in ds-path-* in multigraph leaves
    # are expanded by the Writer post-processing
    if( defined $value and $self->getParamProperty( $param, 'expand' ) )
    {
        $value = $self->_expand_substitutions( $token, $param, $value );
    }
    return $value;
}


sub _expand_substitutions
{
    my $self = shift;
    my $token = shift;
    my $param = shift;
    my $value = shift;

    my $ok = 1;
    my $changed = 1;

    while( $changed and $ok )
    {
        $changed = 0;

        # Substitute definitions
        if( index($value, '$') >= 0 )
        {
            if( not $value =~ /\$(\w+)/o )
            {
                my $path = $self->path($token);
                Error("Incorrect definition reference: $value in $path");
                $ok = 0;
            }
            else
            {
                my $dname = $1;
                my $dvalue = $self->getDefinition($dname);
                if( not defined( $dvalue ) )
                {
                    my $path = $self->path($token);
                    Error("Cannot find definition $dname in $path");
                    $ok = 0;
                }
                else
                {
                    $value =~ s/\$$dname/$dvalue/g;
                    $changed = 1;
                }
            }
        }

        # Substitute parameter references
        if( index($value, '%') >= 0 and $ok )
        {
            if( not $value =~ /\%([a-zA-Z0-9\-_]+)\%/o )
            {
                Error("Incorrect parameter reference: $value");
                $ok = 0;
            }
            else
            {
                my $pname = $1;
                my $pval = $self->getNodeParam( $token, $pname );

                if( not defined( $pval ) )
                {
                    my $path = $self->path($token);
                    Error("Cannot expand parameter reference %".
                          $pname."% in ".$path);
                    $ok = 0;
                }
                else
                {
                    $value =~ s/\%$pname\%/$pval/g;
                    $changed = 1;
                }
            }
        }
    }

    if( ref( $Torrus::ConfigTree::nodeParamHook ) )
    {
        $value = &{$Torrus::ConfigTree::nodeParamHook}( $self, $token,
                                                        $param, $value );
    }

    return $value;
}


sub getNodeParam
{
    my $self = shift;
    my $token = shift;
    my $param = shift;
    my $noclimb = shift;

    my $node = $self->_node_read($token);
    if( not defined($node) )
    {
        return undef;
    }

    if( defined($node->{'xparams'}{$param}) )
    {
        return $node->{'xparams'}{$param};
    }

    my $value;
    if( $noclimb )
    {
        $value = $node->{'params'}{$param};
    }
    else
    {
        $value = $self->_retrieve_node_param( $token, $param );
    }

    if( defined($value) )
    {
        $value = $self->_expand_node_param( $token, $param, $value );
        if( not $self->{'is_writing'} )
        {
            $node->{'xparams'}{$param} = $value;
        }
    }
        
    return $value;
}




sub getOtherParams
{
    my $self = shift;
    my $name = shift;

    my $obj = $self->_other_read($name);

    if( defined($obj) )
    {
        return $obj->{'params'};
    }
    else
    {
        return {};
    }
}


sub getNodeParams
{
    my $self = shift;
    my $token = shift;

    my $obj = $self->_node_read($token);

    if( defined($obj) )
    {
        return $obj->{'params'};
    }
    else
    {
        return {};
    }
}



sub getParent
{
    my $self = shift;
    my $token = shift;

    if( $self->isTset($token) )
    {
        return undef;
    }

    my $node = $self->_node_read($token);
    my $parent = $node->{'parent'};
    
    if( $parent eq '' )
    {
        return undef;
    }
    else
    {
        return $parent;
    }
}


sub getChildren
{
    my $self = shift;
    my $token = shift;

    my $node = $self->_node_read($token);
    if( not $node->{'is_subtree'} )
    {
        return;
    }

    my @ret;
    while( my ($key, $val) = each %{$node->{'children'}} )
    {
        if($val)
        {
            push(@ret, $key);
        }
    }

    return @ret;
}


sub getParamProperty
{
    my $self = shift;
    my $param = shift;
    my $prop = shift;

    return $self->{'paramprop'}{$prop}{$param};
}


sub getParamProperties
{
    my $self = shift;

    return $self->{'paramprop'};
}


#
# Recognizes absolute or relative path, '..' as the parent subtree
#
sub getRelative
{
    my $self = shift;
    my $token = shift;
    my $relPath = shift;

    if( $relPath =~ s/^\[\[(.+)\]\]//o )
    {
        my $nodeid = $1;
        $token = $self->getNodeByNodeid( $nodeid );
        return(undef) unless defined($token);
    }

    if( $relPath =~ /^\//o )
    {
        return $self->token( $relPath );
    }
    else
    {
        if( length( $relPath ) > 0 )
        {
            $token = $self->getParent( $token );
        }

        while( length( $relPath ) > 0 )
        {
            if( $relPath =~ /^\.\.\//o )
            {
                $relPath =~ s/^\.\.\///o;
                if( not $self->isRoot($token) )
                {
                    $token = $self->getParent( $token );
                }
            }
            else
            {
                my $childName;
                $relPath =~ s/^([^\/]*\/?)//o;
                if( defined($1) )
                {
                    $childName = $1;
                }
                else
                {
                    last;
                }
                my $path = $self->path( $token );
                $token = $self->token( $path . $childName );
                if( not defined $token )
                {
                    return undef;
                }
            }
        }
        return $token;
    }
}


sub _nodeid_sha_file
{
    my $self = shift;
    my $nodeid = shift;

    return ('nodeid/' . $self->_sha_file(sha1_hex($nodeid)));
}

sub _nodeidpx_sha_dir
{
    my $self = shift;
    my $prefix = shift;

    return ('nodeidpx/' . $self->_sha_file(sha1_hex($prefix)));
}


sub getNodeByNodeid
{
    my $self = shift;
    my $nodeid = shift;

    my $result = $self->_read_json( $self->_nodeid_sha_file($nodeid) );
    if( defined($result) )
    {
        return $result->[1];
    }
    else
    {
        return undef;
    }
}

# Returns arrayref.
# Each element is an arrayref to [nodeid, token] pair
sub searchNodeidPrefix
{
    my $self = shift;
    my $prefix = shift;

    $prefix =~ s/\/\/$//; # remove trailing separator if any
    my $dir = $self->_nodeidpx_sha_dir($prefix);

    return unless $self->{'store'}->file_exists($dir);

    my @nodeid_sha;
    
    my $cb_read = sub {
        my ($path, $data) = @_;
        my $name = substr($path, rindex($path, '/')+1);
        push(@nodeid_sha, $name);
    };

    $self->{'store'}->recursive_read($dir, $cb_read);
        
    my $ret = [];
    foreach my $sha (@nodeid_sha)
    {
        my $datafile = 'nodeid/' . $self->_sha_file($sha);
        my $content = $self->{'store'}->read_file($datafile);
        die("Cannot read $datafile") unless defined($content);
        push(@{$ret}, $self->{'json'}->decode($content));
    }
    
    return $ret;
}


# Returns arrayref.
# Each element is an arrayref to [nodeid, token] pair
sub searchNodeidSubstring
{
    my $self = shift;
    my $substring = shift;

    my $ret = [];
    my $cb_read = sub {
        my ($path, $data) = @_;
        my $decoded = $self->{'json'}->decode($data);
        if( index($decoded->[0], $substring) >= 0 )
        {
            push(@{$ret}, $decoded);
        }
    };
    
    $self->{'store'}->recursive_read('nodeid', $cb_read);
    return $ret;
}



sub getDefaultView
{
    my $self = shift;
    my $token = shift;

    my $view;
    if( $self->isTset($token) )
    {
        if( $token eq 'SS' )
        {
            $view = $self->getOtherParam('SS', 'default-tsetlist-view');
        }
        else
        {
            $view = $self->getOtherParam($token, 'default-tset-view');
            if( not defined( $view ) )
            {
                $view = $self->getOtherParam('SS', 'default-tset-view');
            }
        }
    }
    elsif( $self->isSubtree($token) )
    {
        $view = $self->getNodeParam($token, 'default-subtree-view');
    }
    else
    {
        # This must be leaf
        $view = $self->getNodeParam($token, 'default-leaf-view');
    }

    if( not defined( $view ) )
    {
        Error("Cannot find default view for $token");
    }
    return $view;
}


sub getInstanceParam
{
    my $self = shift;
    my $type = shift;
    my $name = shift;
    my $param = shift;

    if( $type eq 'node' )
    {
        return $self->getNodeParam($name, $param);
    }
    else
    {
        return $self->getOtherParam($name, $param);
    }
}


sub getInstanceParamsByMap
{
    my $self = shift;
    my $inst_name = shift;
    my $inst_type = shift;
    my $mapref = shift;

    # Debug("Retrieving params for $inst_type $inst_name");

    my $ret = {};
    my @namemaps = ($mapref);

    while( scalar(@namemaps) > 0 )
    {
        my @next_namemaps = ();

        foreach my $namemap (@namemaps)
        {
            foreach my $paramkey (keys %{$namemap})
            {
                # Debug("Checking param: $pname");

                my $pname = $paramkey;
                my $mandatory = 1;
                if( $pname =~ s/^\+//o )
                {
                    $mandatory = 0;
                }

                my $listval = 0;
                if( $pname =~ s/^\@//o )
                {
                    $listval = 1;
                }
                
                my $pvalue =
                    $self->getInstanceParam($inst_type, $inst_name, $pname);

                my @pvalues;
                if( $listval )
                {
                    @pvalues = split(',', $pvalue);
                }
                else
                {
                    @pvalues = ( $pvalue );
                }
                
                if( not defined( $pvalue ) )
                {
                    if( $mandatory )
                    {
                        my $msg;
                        if( $inst_type eq 'node' )
                        {
                            $msg = $self->path( $inst_name );
                        }
                        else
                        {
                            $msg = "$inst_type $inst_name";
                        }
                        Error("Mandatory parameter $pname is not ".
                              "defined for $msg");
                        return undef;
                    }
                }
                else
                {
                    if( ref( $namemap->{$paramkey} ) )
                    {
                        foreach my $pval ( @pvalues )
                        {
                            if( exists $namemap->{$paramkey}->{$pval} )
                            {
                                if( defined $namemap->{$paramkey}->{$pval} )
                                {
                                    push( @next_namemaps,
                                          $namemap->{$paramkey}->{$pval} );
                                }
                            }
                            else
                            {
                                my $msg;
                                if( $inst_type eq 'node' )
                                {
                                    $msg = $self->path( $inst_name );
                                }
                                else
                                {
                                    $msg = "$inst_type $inst_name";
                                }
                                Error("Parameter $pname has ".
                                      "unknown value: $pval for $msg");
                                return undef;
                            }
                        }
                    }

                    $ret->{$pname} = $pvalue;
                }
            }
        }
        @namemaps = @next_namemaps;
    }
    
    return $ret;
}



sub _other_object_names
{
    my $self = shift;
    my $filename = shift;

    my @ret;
    my $data = $self->_read_json('other/' . $filename);
    if( defined($data) )
    {
        foreach my $name ( keys %{$data} )
        {
            if( $data->{$name} )
            {
                push(@ret, $name);
            }
        }
    }

    return @ret;
}

sub _other_object_exists
{
    my $self = shift;
    my $filename = shift;
    my $objname = shift;

    my $data = $self->_read_json('other/' . $filename);

    if( defined($data) )
    {
        return $data->{$objname};
    }

    return undef;
}


sub getViewNames
{
    my $self = shift;
    return $self->_other_object_names('__VIEWS__');
}


sub viewExists
{
    my $self = shift;
    my $vname = shift;
    return $self->_other_object_exists('__VIEWS__', $vname);
}


sub getMonitorNames
{
    my $self = shift;
    return $self->_other_object_names('__MONITORS__');
}


sub monitorExists
{
    my $self = shift;
    my $mname = shift;
    return $self->_other_object_exists('__MONITORS__', $mname);
}


sub getActionNames
{
    my $self = shift;
    return $self->_other_object_names('__ACTIONS__');
}


sub actionExists
{
    my $self = shift;
    my $aname = shift;
    return $self->_other_object_exists('__ACTIONS__', $aname);
}



# Token sets manipulation

sub isTset
{
    my $self = shift;
    my $token = shift;
    return substr($token, 0, 1) eq 'S';
}

sub addTset
{
    my $self = shift;
    my $tset = shift;
    $self->{'redis'}->hset($self->{'redis_prefix'} . 'tsets:' .
                           $self->treeName(), $tset, '1');
    return;
}

sub tsetExists
{
    my $self = shift;
    my $tset = shift;
    return $self->{'redis'}->hget($self->{'redis_prefix'} . 'tsets:' .
                                  $self->treeName(), $tset) ? 1:0;
}

sub getTsets
{
    my $self = shift;
    return $self->{'redis'}->hkeys($self->{'redis_prefix'} . 'tsets:' .
                                   $self->treeName());
}

sub tsetMembers
{
    my $self = shift;
    my $tset = shift;

    return $self->{'redis'}->hkeys($self->{'redis_prefix'} . 'tset:' .
                                   $self->treeName() . ':' . $tset);
}

sub tsetMemberOrigin
{
    my $self = shift;
    my $tset = shift;
    my $token = shift;

    return $self->{'redis'}->hget($self->{'redis_prefix'} . 'tset:' .
                                  $self->treeName() . ':' . $tset,
                                  $token);
}

sub tsetAddMember
{
    my $self = shift;
    my $tset = shift;
    my $token = shift;
    my $origin = shift;

    $self->{'redis'}->hset($self->{'redis_prefix'} . 'tset:' .
                           $self->treeName() . ':' . $tset,
                           $token,
                           $origin);
    return;
}


sub tsetDelMember
{
    my $self = shift;
    my $tset = shift;
    my $token = shift;

    $self->{'redis'}->hdel($self->{'redis_prefix'} . 'tset:' .
                           $self->treeName() . ':' . $tset,
                           $token);
    return;
}

# Definitions manipulation

sub getDefinition
{
    my $self = shift;
    my $name = shift;

    my $def = $self->{'defs'}{$name};
    if( not defined($def) )
    {
        $def = $self->_read_json('definitions/' . $name);
        $self->{'defs'}{$name} = $def;
    }
            
    return $def;
}


sub getDefinitionNames
{
    my $self = shift;

    my @ret;
    
    my $cb_read = sub {
        my ($path, $data) = @_;
        my $name = substr($path, rindex($path, '/')+1);
        push(@ret, $name);
    };

    $self->{'store'}->recursive_read('definitions', $cb_read);
    return @ret;
}


sub getSrcFiles
{
    my $self = shift;
    my $token = shift;

    my $node = $self->_node_read($token);
    if( defined($node->{'src'}) )
    {
        return sort keys %{$node->{'src'}};
    }
    else
    {
        return ();
    }
}




sub getUpdates
{
    my $self = shift;
    my $old_commit_id = shift;
    my $cb_token_updated = shift;
    my $cb_token_deleted = shift;

    my $cb_updated = sub {
        my $token = $self->_token_from_path($_[0]);
        if( defined($token) )
        {
            &{$cb_token_updated}($token);
        }
    };

    my $cb_deleted = sub {
        my $token = $self->_token_from_path($_[0]);
        if( defined($token) )
        {
            &{$cb_token_deleted}($token);
        }
    };

    if( defined($old_commit_id) and $old_commit_id ne '' )
    {
        if( $old_commit_id ne $self->currentCommit() )
        {
            $self->{'store'}->read_updates(
                $old_commit_id, $cb_updated, $cb_deleted, 1);
        }
    }
    else
    {
        $self->{'store'}->recursive_read('nodes', $cb_updated, 1);
    }
}


sub _token_from_path
{
    my $self = shift;
    my $path = shift;

    if( $path =~ /^nodes\/(.+)/o )
    {
        my $token = $1;
        $token =~ s/\///og;
        return $token;
    }
    return undef;
}
            


1;


# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 4
# End:
