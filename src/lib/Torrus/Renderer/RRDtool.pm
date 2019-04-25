#  Copyright (C) 2002-2011  Stanislav Sinyagin
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

package Torrus::Renderer::RRDtool;
use strict;
use warnings;

use Torrus::ConfigTree;
use Torrus::RPN;
use Torrus::Log;

use RRDs;
use IO::File;

# All our methods are imported by Torrus::Renderer;

my %rrd_graph_opts =
    (
     'start'  => '--start',
     'end'    => '--end',
     'width'  => '--width',
     'height' => '--height',
     'imgformat' => '--imgformat',
     'border' => '--border',
    );

my %mime_type =
    ('PNG' => 'image/png',
     'SVG' => 'image/svg+xml',
     'EPS' => 'application/postscript',
     'PDF' => 'application/pdf');

my @arg_arrays = qw(opts defs bg hwtick hwline line hrule fg);


sub prepare_rrgraph_args
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $opt = shift;

    $opt = {} unless defined($opt);

    my $obj = {'args' => {}, 'dname' => 'A'};

    foreach my $arrayName ( @arg_arrays )
    {
        $obj->{'args'}{$arrayName} = [];
    }

    push( @{$obj->{'args'}{'opts'}},
          $self->rrd_make_opts( $config_tree, $token, $view,
                                \%rrd_graph_opts, $obj ) );

    push( @{$obj->{'args'}{'opts'}},
          $self->rrd_make_graph_opts( $config_tree, $token, $view ) );

    my $dstype = $config_tree->getNodeParam($token, 'ds-type');

    if( $dstype eq 'rrd-multigraph' )
    {
        $self->rrd_make_multigraph( $config_tree, $token, $view, $obj );
    }
    else
    {
        my $showmax = 0;
        my $max_dname = $obj->{'dname'} . '_Max';

        my $leaftype = $config_tree->getNodeParam($token, 'leaf-type');

        # Handle DEFs and CDEFs
        # At the moment, we call the DEF as 'A'. Could change in the future
        if( $leaftype eq 'rrd-def' )
        {
            my $defstring =
                $self->rrd_make_def( $config_tree, $token, $obj->{'dname'} );
            return(undef) unless defined($defstring);

            push( @{$obj->{'args'}{'defs'}}, $defstring );

            if( $self->rrd_check_hw( $config_tree, $token, $view ) )
            {
                $self->rrd_make_holtwinters( $config_tree, $token,
                                             $view, $obj );
            }
            else
            {
                if( $self->rrd_if_showmax($config_tree, $token, $view) )
                {
                    my $step =
                        $self->rrd_maxline_step( $config_tree, $view );

                    my $maxdef =
                        $self->rrd_make_def( $config_tree, $token,
                                             $max_dname, 'MAX',
                                             {'step' => $step});

                    push( @{$obj->{'args'}{'defs'}}, $maxdef );
                    $showmax = 1;
                }
            }
        }
        elsif( $leaftype eq 'rrd-cdef' )
        {
            my $expr = $config_tree->getNodeParam($token, 'rpn-expr');
            push( @{$obj->{'args'}{'defs'}},
                  $self->rrd_make_cdef($config_tree, $token,
                                       $obj->{'dname'}, $expr) );

            if( $self->rrd_if_showmax($config_tree, $token, $view) )
            {
                my $step =
                    $self->rrd_maxline_step( $config_tree, $view );

                push( @{$obj->{'args'}{'defs'}},
                      $self->rrd_make_cdef( $config_tree, $token,
                                            $max_dname, $expr,
                                            {'force_function' => 'MAX',
                                             'step' => $step} ) );

                $showmax = 1;
            }
        }
        else
        {
            Error("Unsupported leaf-type: $leaftype");
            return undef;
        }

        $self->rrd_make_graphline( $config_tree, $token, $view, $obj );

        if( $showmax )
        {
            $self->rrd_make_maxline( $max_dname, $config_tree,
                                     $token, $view, $obj );
        }
    }

    return(undef) if $obj->{'error'};

    if( not $opt->{'data_only'} )
    {
        $self->rrd_make_hrules( $config_tree, $token, $view, $obj );
        if( not $Torrus::Renderer::ignoreDecorations )
        {
            $self->rrd_make_decorations( $config_tree, $token, $view, $obj );
        }
    }

    # We're all set

    my $args = [];
    if( defined($Torrus::Global::RRDCachedSock) )
    {
        push( @{$args}, "--daemon=unix:" . $Torrus::Global::RRDCachedSock );
    }

    foreach my $arrayName ( @arg_arrays )
    {
        push( @{$args}, @{$obj->{'args'}{$arrayName}} );
    }

    return ($args, $obj);
}



sub render_rrgraph
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $outfile = shift;

    if( not $config_tree->isLeaf($token) )
    {
        Error("Token $token is not a leaf");
        return undef;
    }

    my ($args, $obj) =
        $self->prepare_rrgraph_args($config_tree, $token, $view);
    if( not defined($args) )
    {
        return undef;
    }    
    
    Debug("RRDs::graph arguments: " . join(' ', @{$args}));

    # localize the TZ enviromennt for the child process
    {
        my $tz = $self->{'options'}->{'variables'}->{'TZ'};
        if( not defined($tz) )
        {
            $tz = $ENV{'TZ'};
        }

        local $ENV{'TZ'};
        if( defined($tz) )
        {
            $ENV{'TZ'} = $tz;
        }

        &RRDs::graph( $outfile, @{$args} );
    }

    my $ERR=RRDs::error;
    if( $ERR )
    {
        my $path = $config_tree->path($token);
        Error("$path $view: Error during RRD graph: $ERR");
        return undef;
    }

    my $mimetype = $obj->{'mimetype'};
    if( not defined($mimetype) )
    {
        $mimetype = 'image/png';
    }

    return( $config_tree->getOtherParam($view, 'expires')+time(), $mimetype );
}


my %rrd_print_opts =
    (
     'start'  => '--start',
     'end'    => '--end',
     );



sub render_rrprint
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $outfile = shift;

    if( not $config_tree->isLeaf($token) )
    {
        Error("Token $token is not a leaf");
        return undef;
    }

    my @arg_opts;
    my @arg_defs;
    my @arg_print;

    push( @arg_opts, $self->rrd_make_opts( $config_tree, $token, $view,
                                           \%rrd_print_opts, ) );

    my $dstype = $config_tree->getNodeParam($token, 'ds-type');

    if( $dstype eq 'rrd-multigraph' )
    {
        Error("View type rrprint is not supported ".
              "for DS type rrd-multigraph");
        return undef;
    }

    my $leaftype = $config_tree->getNodeParam($token, 'leaf-type');

    # Handle DEFs and CDEFs
    # At the moment, we call the DEF as 'A'. Could change in the future
    my $dname = 'A';
    if( $leaftype eq 'rrd-def' )
    {
        my $defstring = $self->rrd_make_def( $config_tree, $token, $dname );
        return(undef) unless defined($defstring);
        push( @arg_defs, $defstring );
    }
    elsif( $leaftype eq 'rrd-cdef' )
    {
        my $expr = $config_tree->getNodeParam($token, 'rpn-expr');
        push( @arg_defs,
              $self->rrd_make_cdef($config_tree, $token, $dname, $expr));
    }
    else
    {
        Error("Unsupported leaf-type: $leaftype");
        return undef;
    }

    foreach my $cf
        ( split(',', $config_tree->getOtherParam($view, 'print-cf')) )
    {
        push( @arg_print, sprintf( 'PRINT:%s:%s:%%le', $dname, $cf ) );
    }

    # We're all set

    my @args = ( @arg_opts, @arg_defs, @arg_print );
    Debug("RRDs::graph arguments: " . join(' ', @args));

    my $printout;

    # localize the TZ enviromennt for the child process
    {
        my $tz = $self->{'options'}->{'variables'}->{'TZ'};
        if( not defined($tz) )
        {
            $tz = $ENV{'TZ'};
        }

        local $ENV{'TZ'};
        if( defined($tz) )
        {
            $ENV{'TZ'} = $tz;
        }

        ($printout, undef, undef) = RRDs::graph('/dev/null', @args);
    }

    my $ERR=RRDs::error;
    if( $ERR )
    {
        my $path = $config_tree->path($token);
        Error("$path $view: Error during RRD graph: $ERR");
        return undef;
    }

    my $fh = IO::File->new($outfile, 'w');
    if( not defined($fh) )
    {
        Error("Cannot open $outfile for writing: $!");
        return undef;
    }
    else
    {
        $fh->printf("%s\n", join(':', @{$printout}));
        $fh->close();
    }

    return( $config_tree->getOtherParam($view, 'expires')+time(),
            'text/plain' );
}



sub rrd_make_multigraph
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $obj = shift;

    my @dsNames =
        split(',', $config_tree->getNodeParam($token, 'ds-names') );

    # We need this to refer to some existing variable name
    $obj->{'dname'} = $dsNames[0];

    my $showmax = $self->rrd_if_showmax($config_tree, $token, $view);

    # Analyze the drawing order
    my %dsOrder;
    foreach my $dname ( @dsNames )
    {
        my $order = $config_tree->getNodeParam($token, 'line-order-'.$dname);
        $dsOrder{$dname} = defined( $order ) ? $order : 100;
    }

    my $disable_legend = $config_tree->getOtherParam($view, 'disable-legend');

    $disable_legend =
        (defined($disable_legend) and $disable_legend eq 'yes') ? 1:0;

    # make DEFs and Line instructions

    my $do_gprint = 0;

    if( not $disable_legend )
    {
        $do_gprint = $self->rrd_if_gprint( $config_tree, $token );
        if( $do_gprint )
        {
            $self->rrd_make_gprint_header( $config_tree, $token, $view, $obj );
        }
    }

    foreach my $dname ( sort {$dsOrder{$a} <=> $dsOrder{$b}} @dsNames )
    {
        my $dograph = 1;
        my $ignoreViews =
            $config_tree->getNodeParam($token, 'ignore-views-'.$dname);
        if( defined( $ignoreViews ) and
            grep {$_ eq $view} split(',', $ignoreViews) )
        {
            $dograph = 0;
        }

        my $gprint_this = $do_gprint;
        if( $do_gprint )
        {
            my $ds_nogprint =
                $config_tree->getNodeParam($token, 'disable-gprint-'.$dname);
            if( defined( $ds_nogprint ) and $ds_nogprint eq 'yes' )
            {
                $gprint_this = 0;
            }
        }

        my $legend = '';
        my $ds_expr;

        if( $dograph or $gprint_this )
        {
            $ds_expr = $config_tree->getNodeParam($token, 'ds-expr-'.$dname);
            my @cdefs =
                $self->rrd_make_cdef($config_tree, $token, $dname, $ds_expr);
            if( not scalar(@cdefs) )
            {
                $obj->{'error'} = 1;
                next;
            }

            push( @{$obj->{'args'}{'defs'}}, @cdefs );

            $legend =
                $config_tree->getNodeParam($token, 'graph-legend-'.$dname);
            if( defined( $legend ) )
            {
                $legend =~ s/:/\\:/g;
            }
            else
            {
                $legend = '';
            }
        }

        if( $gprint_this )
        {
            $self->rrd_make_gprint( $dname, $legend,
                                    $config_tree, $token, $view, $obj );
            if( not $dograph )
            {
                push( @{$obj->{'args'}{'line'}},
                      'COMMENT:' . $legend . '\l');
            }
        }
        else
        {
            # For datasource that disables gprint, there's no reason
            # to print the label
            $legend = '';
        }

        if( $dograph )
        {
            my $linestyle =
                $self->mkline( $config_tree->getNodeParam
                               ($token, 'line-style-'.$dname) );

            my $linecolor =
                $self->mkcolor( $config_tree->getNodeParam
                                ($token, 'line-color-'.$dname) );

            my $alpha =
                $config_tree->getNodeParam($token, 'line-alpha-'.$dname);
            if( defined( $alpha ) )
            {
                $linecolor .= $alpha;
            }

            my $stack =
                $config_tree->getNodeParam($token, 'line-stack-'.$dname);
            if( defined( $stack ) and $stack eq 'yes' )
            {
                $stack = ':STACK';
            }
            else
            {
                $stack = '';
            }

            if( $showmax and ($stack eq '') )
            {
                my $max_dname = $dname . '_Max';

                my $p_maxlinestyle =
                    $config_tree->getNodeParam($token,
                                               'maxline-style-'.$dname);

                my $p_maxlinecolor =
                    $config_tree->getNodeParam($token,
                                               'maxline-color-'.$dname);

                my $step =
                    $self->rrd_maxline_step( $config_tree, $view );

                if( defined($p_maxlinestyle) and defined($p_maxlinecolor) )
                {
                    my @cdefs =
                        $self->rrd_make_cdef($config_tree, $token,
                                             $max_dname, $ds_expr,
                                             {'force_function' => 'MAX',
                                              'step' => $step});
                    if( not scalar(@cdefs) )
                    {
                        $obj->{'error'} = 1;
                        next;
                    }

                    push( @{$obj->{'args'}{'defs'}}, @cdefs );

                    my $max_linestyle = $self->mkline( $p_maxlinestyle );
                    my $max_linecolor = $self->mkcolor( $p_maxlinecolor );
                    if( defined( $alpha ) )
                    {
                        $max_linecolor .= $alpha;
                    }

                    push( @{$obj->{'args'}{'line'}},
                          sprintf( '%s:%s%s',
                                   $max_linestyle,
                                   $max_dname,
                                   $max_linecolor ) );
                }
            }

            push( @{$obj->{'args'}{'line'}},
                  sprintf( '%s:%s%s%s%s', $linestyle, $dname,
                           $linecolor,
                           ($legend ne '') ? ':'.$legend.'\l' : ':\l',
                           $stack ) );
        }
    }
    return;
}


# Check if Holt-Winters stuff is needed
sub rrd_check_hw
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;

    my $use_hw = 0;
    my $nodeHW = $config_tree->getNodeParam($token, 'rrd-hwpredict');
    if( defined($nodeHW) and $nodeHW eq 'enabled' )
    {
        my $viewHW = $config_tree->getOtherParam($view, 'rrd-hwpredict');
        my $varNoHW = $self->{'options'}->{'variables'}->{'NOHW'};

        if( (not defined($viewHW) or $viewHW ne 'disabled') and
            (not $varNoHW) )
        {
            $use_hw = 1;
        }
    }
    return $use_hw;
}


sub rrd_make_holtwinters
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $obj = shift;

    my $dname = $obj->{'dname'};

    my $defstring = $self->rrd_make_def( $config_tree, $token,
                                         $dname . 'pred', 'HWPREDICT' );
    return() unless defined($defstring);
    push( @{$obj->{'args'}{'defs'}}, $defstring );

    $defstring = $self->rrd_make_def( $config_tree, $token,
                                      $dname . 'dev', 'DEVPREDICT' );
    return() unless defined($defstring);
    push( @{$obj->{'args'}{'defs'}}, $defstring );

    # Upper boundary definition
    push( @{$obj->{'args'}{'defs'}},
          sprintf( 'CDEF:%supper=%spred,%sdev,2,*,+',
                   $dname, $dname, $dname  ) );

    # Lower boundary definition
    push( @{$obj->{'args'}{'defs'}},
          sprintf( 'CDEF:%slower=%spred,%sdev,2,*,-',
                   $dname, $dname, $dname  ) );

    # Failures definition
    $defstring = $self->rrd_make_def( $config_tree, $token,
                                      $dname . 'fail', 'FAILURES' );
    return() unless defined($defstring);
    push( @{$obj->{'args'}{'defs'}}, $defstring );

    # Generate H-W Boundary Lines

    # Boundary style
    my $hw_bndr_style = $config_tree->getOtherParam($view, 'hw-bndr-style');
    $hw_bndr_style = 'LINE1' unless defined $hw_bndr_style;
    $hw_bndr_style = $self->mkline( $hw_bndr_style );

    my $hw_bndr_color = $config_tree->getOtherParam($view, 'hw-bndr-color');
    $hw_bndr_color = '#FF0000' unless defined $hw_bndr_color;
    $hw_bndr_color = $self->mkcolor( $hw_bndr_color );

    push( @{$obj->{'args'}{'hwline'}},
          sprintf( '%s:%supper%s:%s',
                   $hw_bndr_style, $dname, $hw_bndr_color,
                   $Torrus::Renderer::hwGraphLegend ? 'Boundaries\n':'' ) );
    push( @{$obj->{'args'}{'hwline'}},
          sprintf( '%s:%slower%s',
                   $hw_bndr_style, $dname, $hw_bndr_color ) );

    # Failures Tick

    my $hw_fail_color = $config_tree->getOtherParam($view, 'hw-fail-color');
    $hw_fail_color = '#FFFFA0' unless defined $hw_fail_color;
    $hw_fail_color = $self->mkcolor( $hw_fail_color );

    push( @{$obj->{'args'}{'hwtick'}},
          sprintf( 'TICK:%sfail%s:1.0:%s',
                   $dname, $hw_fail_color,
                   $Torrus::Renderer::hwGraphLegend ? 'Failures':'') );
    return;
}



sub rrd_make_graphline
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $obj = shift;

    my $legend;

    my $disable_legend = $config_tree->getOtherParam($view, 'disable-legend');
    if( not defined($disable_legend) or $disable_legend ne 'yes' )
    {
        $legend = $config_tree->getNodeParam($token, 'graph-legend');
        if( defined( $legend ) )
        {
            $legend =~ s/:/\\:/g;
        }
    }

    if( not defined( $legend ) )
    {
        $legend = '';
    }

    my $styleval = $config_tree->getNodeParam($token, 'line-style');
    if( not defined($styleval)  )
    {
        $styleval = $config_tree->getOtherParam($view, 'line-style');
    }

    my $linestyle = $self->mkline( $styleval );

    my $colorval = $config_tree->getNodeParam($token, 'line-color');
    if( not defined($colorval) )
    {
        $colorval = $config_tree->getOtherParam($view, 'line-color');
    }

    my $linecolor = $self->mkcolor( $colorval );

    if( $self->rrd_if_gprint( $config_tree, $token ) )
    {
        $self->rrd_make_gprint_header( $config_tree, $token, $view, $obj );

        $self->rrd_make_gprint( $obj->{'dname'}, $legend,
                                $config_tree, $token, $view, $obj );
    }

    push( @{$obj->{'args'}{'line'}},
          sprintf( '%s:%s%s%s', $linestyle, $obj->{'dname'}, $linecolor,
                   ($legend ne '') ? ':'.$legend.'\l' : '' ) );
    if( $legend eq '' )
    {
        push( @{$obj->{'args'}{'line'}}, 'COMMENT:\l' );
    }

    return;
}


sub rrd_make_maxline
{
    my $self = shift;
    my $max_dname = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $obj = shift;

    my $legend;

    my $disable_legend = $config_tree->getOtherParam($view, 'disable-legend');
    if( not defined($disable_legend) or $disable_legend ne 'yes' )
    {
        $legend = $config_tree->getNodeParam($token, 'graph-legend');
        if( defined( $legend ) )
        {
            $legend =~ s/:/\\:/g;
        }
    }

    if( not defined( $legend ) )
    {
        $legend = 'Max';
    }
    else
    {
        $legend = 'Max ' . $legend;
    }

    my $styleval = $config_tree->getNodeParam($token, 'maxline-style');
    if( not defined($styleval)  )
    {
        $styleval = $config_tree->getOtherParam($view, 'maxline-style');
    }

    my $linestyle = $self->mkline( $styleval );

    my $colorval = $config_tree->getNodeParam($token, 'maxline-color');
    if( not defined($colorval) )
    {
        $colorval = $config_tree->getOtherParam($view, 'maxline-color');
    }

    my $linecolor = $self->mkcolor( $colorval );

    if( $self->rrd_if_gprint( $config_tree, $token ) )
    {
        $self->rrd_make_gprint( $max_dname, $legend,
                                $config_tree, $token, $view, $obj );
    }

    push( @{$obj->{'args'}{'line'}},
          sprintf( '%s:%s%s%s', $linestyle, $max_dname, $linecolor,
                   ($legend ne '') ? ':'.$legend.'\l' : ':\l' ) );
    return;
}


# Generate RRDtool arguments for HRULE's

sub rrd_make_hrules
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $obj = shift;

    my $hrulesList = $config_tree->getOtherParam($view, 'hrules');
    if( defined( $hrulesList ) )
    {
        foreach my $hruleName ( split(',', $hrulesList ) )
        {
            # The presence of this parameter is checked by Validator
            my $valueParam =
                $config_tree->getOtherParam( $view, 'hrule-value-'.$hruleName );
            my $value = $config_tree->getNodeParam( $token, $valueParam );

            if( defined( $value ) )
            {
                my $style =
                    $config_tree->getOtherParam($view,
                                                'hrule-color-'.$hruleName);

                my $color = $self->mkcolor( $style );
                my $line = $self->mkline( $style );

                my $legend =
                    $config_tree->getNodeParam($token,
                                               'hrule-legend-'.$hruleName);

                my $arg = sprintf( '%s:%e%s::skipscale',
                                   $line, $value, $color );
                if( defined( $legend ) and $legend =~ /\S/ )
                {
                    $arg .= ':' . $legend . '\l';
                }
                push( @{$obj->{'args'}{'hrule'}}, $arg );
            }
        }
    }
    return;
}


sub rrd_make_decorations
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $obj = shift;

    my $decorList = $config_tree->getOtherParam($view, 'decorations');
    my $ignore_decor =
        $config_tree->getNodeParam($token, 'graph-ignore-decorations');
    if( defined( $decorList ) and
        (not defined($ignore_decor) or $ignore_decor ne 'yes') )
    {
        my $decor = {};
        foreach my $decorName ( split(',', $decorList ) )
        {
            my $order =
                $config_tree->getOtherParam($view, 'dec-order-' . $decorName);
            $decor->{$order} = {'def' => [], 'line' => ''};

            my $style =
                $self->mkline($config_tree->
                              getOtherParam($view, 'dec-style-' . $decorName));
            my $color =
                $self->mkcolor($config_tree->
                               getOtherParam($view, 'dec-color-' . $decorName));
            my $expr = $config_tree->
                getOtherParam($view, 'dec-expr-' . $decorName);

            my @cdefs =
                $self->rrd_make_cdef( $config_tree, $token, $decorName,
                                      $obj->{'dname'} . ',POP,' . $expr );
            if( scalar(@cdefs) )
            {
                push( @{$decor->{$order}{'def'}}, @cdefs );
                $decor->{$order}{'line'} =
                    sprintf( '%s:%s%s', $style, $decorName, $color );
            }
            else
            {
                $obj->{'error'} = 1;
            }
        }

        foreach my $order ( sort {$a<=>$b} keys %{$decor} )
        {
            my $array = $order < 0 ? 'bg':'fg';

            push( @{$obj->{'args'}{'defs'}}, @{$decor->{$order}{'def'}} );
            push( @{$obj->{'args'}{$array}}, $decor->{$order}{'line'} );
        }
    }
    return;
}

# Takes the parameters from the view, and composes the list of
# RRDtool arguments

sub rrd_make_opts
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $opthash = shift;
    my $obj = shift;

    my @args = ();
    foreach my $param ( keys %{$opthash} )
    {
        my $value =
            $self->{'options'}->{'variables'}->{'G' . $param};

        if( not defined( $value ) )
        {
            $value = $config_tree->getOtherParam( $view, $param );
        }

        if( defined( $value ) )
        {
            if( ( $param eq 'start' or $param eq 'end' ) and
                defined( $self->{'options'}->{'variables'}->{'NOW'} ) )
            {
                my $now = $self->{'options'}->{'variables'}->{'NOW'};
                if( index( $value , 'now' ) >= 0 )
                {
                    $value =~ s/now/$now/;
                }
                elsif( $value =~ /^(\-|\+)/ )
                {
                    $value = $now . $value;
                }
            }
            elsif( $param eq 'imgformat' )
            {
                if( not defined($mime_type{$value}) )
                {
                    Error('Unsupported value for imgformat: ' . $value);
                    $value = 'PNG';
                }

                if( defined($obj) )
                {
                    $obj->{'mimetype'} = $mime_type{$value};
                }
            }

            push( @args, $opthash->{$param}, $value );
        }
    }

    my $params = $config_tree->getOtherParam($view, 'rrd-params');
    if( defined( $params ) )
    {
        push( @args, split('\s+', $params) );
    }

    my $scalingbase = $config_tree->getNodeParam($token, 'rrd-scaling-base');
    if( defined($scalingbase) and $scalingbase == 1024 )
    {
        push( @args, '--base', '1024' );
    }

    return @args;
}


sub rrd_make_graph_opts
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;

    my @args;

    my $graph_log = $config_tree->getNodeParam($token, 'graph-logarithmic');
    if( defined($graph_log) and $graph_log eq 'yes' )
    {
        push( @args, '--logarithmic' );
    }

    my $disable_title =
        $config_tree->getOtherParam($view, 'disable-title');
    if( not defined( $disable_title ) or $disable_title ne 'yes' )
    {
        my $title = $config_tree->getNodeParam($token, 'graph-title');
        if( not defined($title) )
        {
            $title = ' ';
        }
        push( @args, '--title', $title );
    }

    my $disable_vlabel =
        $config_tree->getOtherParam($view, 'disable-vertical-label');
    if( not defined( $disable_vlabel ) or $disable_vlabel ne 'yes' )
    {
        my $vertical_label =
            $config_tree->getNodeParam($token, 'vertical-label');
        if( defined( $vertical_label ) )
        {
            push( @args, '--vertical-label', $vertical_label );
        }
    }

    my $ignore_limits = $config_tree->getOtherParam($view, 'ignore-limits');
    if( not defined($ignore_limits) or $ignore_limits ne 'yes' )
    {
        my $ignore_lower =
            $config_tree->getOtherParam($view, 'ignore-lower-limit');
        if( not defined($ignore_lower) or $ignore_lower ne 'yes' )
        {
            my $limit =
                $config_tree->getNodeParam($token, 'graph-lower-limit');
            if( defined($limit) )
            {
                push( @args, '--lower-limit', $limit );
            }
        }

        my $ignore_upper =
            $config_tree->getOtherParam($view, 'ignore-upper-limit');
        if( not defined($ignore_upper) or $ignore_upper ne 'yes' )
        {
            my $limit =
                $config_tree->getNodeParam($token, 'graph-upper-limit');
            if( defined($limit) )
            {
                push( @args, '--upper-limit', $limit );
            }
        }

        my $rigid_boundaries =
            $config_tree->getNodeParam($token, 'graph-rigid-boundaries');
        if( defined($rigid_boundaries) and $rigid_boundaries eq 'yes' )
        {
            push( @args, '--rigid' );
        }
    }

    # take colors from view and URL params
    my $colorval =
        $self->{'options'}->{'variables'}->{'Gcolors'};

    if( not defined( $colorval ) )
    {
        $colorval = $config_tree->getOtherParam( $view, 'graph-colors' );
    }

    if( defined( $colorval ) )
    {
        my @values = split( /:/, $colorval );
        if( (scalar(@values) % 2) != 0 )
        {
            Error("Graph colors should be an even number of " .
                  "elements separated by colon: " . $colorval);
        }
        else
        {
            while( scalar(@values) )
            {
                my $tag = shift @values;
                my $color = shift @values;
                if( $tag !~ /^[A-Z]+$/o )
                {
                    Error("Invalid format for color tag in graph colors: " .
                          $colorval);
                }
                elsif( $color !~ /^[0-9A-F]{6}([0-9A-F]{2})?$/io )
                {
                    Error("Invalid format for color value in graph colors: " .
                          $colorval);
                }
                else
                {
                    push( @args, '--color', $tag . '#' . $color );
                }
            }
        }

    }

    if( scalar( @Torrus::Renderer::graphExtraArgs ) > 0 )
    {
        push( @args, @Torrus::Renderer::graphExtraArgs );
    }

    return @args;
}


sub rrd_make_def
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $dname = shift;
    my $cf = shift;
    my $opts = shift;

    my $datafile = $config_tree->getNodeParam($token, 'data-file');
    my $dataddir = $config_tree->getNodeParam($token, 'data-dir');
    my $rrdfile = $dataddir.'/'.$datafile;
    if( not -r $rrdfile )
    {
        my $path = $config_tree->path($token);
        Error("$path: No such file or directory: $rrdfile");
        return undef;
    }

    my $ds = $config_tree->getNodeParam($token, 'rrd-ds');
    if( not defined $cf )
    {
        $cf = $config_tree->getNodeParam($token, 'rrd-cf');
    }

    my $def_options = '';
    my $step = $config_tree->getNodeParam($token, 'graph-step');

    if( defined($opts) and defined($opts->{'step'}) )
    {
        $step = $opts->{'step'};
    }

    if( defined($step) )
    {
        $def_options .= ':step=' . $step;
    }

    return sprintf( 'DEF:%s=%s:%s:%s%s',
                    $dname, $rrdfile, $ds, $cf, $def_options );
}



my %cfNames =
    ( 'AVERAGE' => 1,
      'MIN'     => 1,
      'MAX'     => 1,
      'LAST'    => 1 );

# Moved the validation part to Torrus::ConfigTree::Validator
sub rrd_make_cdef
{
    my $self  = shift;
    my $config_tree = shift;
    my $token = shift;
    my $dname = shift;
    my $expr  = shift;
    my $opts = shift;

    my @args = ();
    my $ok = 1;

    my $step = $config_tree->getNodeParam($token, 'graph-step');
    if( defined($opts) and defined($opts->{'step'}) )
    {
        $step = $opts->{'step'};
    }

    # We will name the DEFs as $dname.sprintf('%.2d', $ds_couter++);
    my $ds_couter = 1;

    my $rpn = new Torrus::RPN;

    # The callback for RPN translation
    my $callback = sub
    {
        my ($noderef, $timeoffset) = @_;

        my $function;
        if( defined($opts) and defined($opts->{'force_function'}) )
        {
            $function = $opts->{'force_function'};
        }
        elsif( $noderef =~ s/^(.+)\@// )
        {
            $function = $1;
        }

        my $cf;
        if( defined( $function ) and $cfNames{$function} )
        {
            $cf = $function;
        }

        my $leaf = ($noderef ne '') ?
            $config_tree->getRelative($token, $noderef) : $token;

        my $varname = $dname . sprintf('%.2d', $ds_couter++);
        my $defstring =
            $self->rrd_make_def( $config_tree, $leaf, $varname, $cf );
        if( not defined($defstring) )
        {
            $ok = 0;
        }
        else
        {
            if( defined($step) )
            {
                $defstring .= ':step=' . $step;
            }
            push( @args, $defstring );
        }
        return $varname;
    };

    $expr = $rpn->translate( $expr, $callback );
    return() unless $ok;
    push( @args, sprintf( 'CDEF:%s=%s', $dname, $expr ) );

    return @args;
}


sub rrd_if_gprint
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;

    my $disable = $config_tree->getNodeParam($token, 'graph-disable-gprint');
    if( defined( $disable ) and $disable eq 'yes' )
    {
        return 0;
    }
    return 1;
}


# determine if MAX line should be drawn
sub rrd_if_showmax
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;

    my $disable = $config_tree->getNodeParam($token, 'graph-disable-maxline');
    if( defined( $disable ) and $disable eq 'yes' )
    {
        return 0;
    }

    if( $self->{'options'}->{'variables'}->{'Gmaxline'} )
    {
        return 1;
    }

    my $enable = $config_tree->getOtherParam($view, 'draw-maxline');
    if( defined($enable) and $enable eq 'yes' )
    {
        return 1;
    }

    return 0;
}

# determine the aggregation step for MAX line
sub rrd_maxline_step
{
    my $self = shift;
    my $config_tree = shift;
    my $view = shift;

    my $step = $config_tree->getOtherParam($view, 'maxline-step');
    if( not defined($step) )
    {
        $step = 86400;
    }

    my $var = $self->{'options'}->{'variables'}->{'Gmaxlinestep'};

    if( defined($var) )
    {
        $step = $var;
    }

    return $step;
}




sub rrd_make_gprint
{
    my $self = shift;
    my $vname = shift;
    my $legend = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $obj = shift;

    my @args = ();

    my $gprintValues = $config_tree->getOtherParam($view, 'gprint-values');
    if( defined( $gprintValues ) )
    {
        foreach my $gprintVal ( split(',', $gprintValues ) )
        {
            my $format =
                $config_tree->getOtherParam($view,
                                            'gprint-format-' . $gprintVal);
            push( @args, 'GPRINT:' . $vname . ':' . $format );
        }
    }

    push( @{$obj->{'args'}{'line'}}, @args );
    return;
}


sub rrd_make_gprint_header
{
    my $self = shift;
    my $config_tree = shift;
    my $token = shift;
    my $view = shift;
    my $obj = shift;

    my $gprintValues = $config_tree->getOtherParam($view, 'gprint-values');
    if( defined( $gprintValues ) )
    {
        my $gprintHeader = $config_tree->getOtherParam($view, 'gprint-header');
        if( defined( $gprintHeader ) )
        {
            push( @{$obj->{'args'}{'line'}},
                  'COMMENT:' . $gprintHeader . '\l' );
        }
    }
    return;
}


sub mkcolor
{
    my $self = shift;
    my $color = shift;

    my $alpha;
    my $recursionLimit = 10;

    while( $color =~ /^\#\#(\S+)$/ )
    {
        if( $recursionLimit-- <= 0 )
        {
            Error('Color recursion is too deep');
            $color = '#000000';
        }
        else
        {
            my $colorName = $1;
            $color = $Torrus::Renderer::graphStyles{$colorName}{'color'};
            if( not defined( $color ) )
            {
                Error('No color is defined for ' . $colorName);
                $color = '#000000';
            }

            my $new_alpha =
                $Torrus::Renderer::graphStyles{$colorName}{'alpha'};
            if( defined($new_alpha) )
            {
                $alpha = $new_alpha;
            }
        }
    }

    $alpha = '' unless defined($alpha);

    return ($color . $alpha);
}

sub mkline
{
    my $self = shift;
    my $line = shift;

    if( $line =~ /^\#\#(\S+)$/ )
    {
        my $lineName = $1;
        $line = $Torrus::Renderer::graphStyles{$lineName}{'line'};
        if( not defined( $line ) )
        {
            Error('No line style is defined for ' . $lineName);
            $line = 'LINE1';
        }
    }
    return $line;
}




1;


# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 4
# End:
