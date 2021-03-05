###############################################################################
#
# Developed with Kate
#
#  (c) 2017-2021 Copyright: Marko Oldenburg (fhemdevelopment at cooltux dot net)
#  All rights reserved
#
#  This script is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#
# $Id$
#
###############################################################################
##
##
## Das JSON Modul immer in einem eval aufrufen
# $data = eval{decode_json($data)};
#
# if($@){
#   Log3($SELF, 2, "$TYPE ($SELF) - error while request: $@");
#
#   readingsSingleUpdate($hash, "state", "error", 1);
#
#   return;
# }
#
#######
#######
#  URLs zum Abrufen diverser Daten
# https://<ip-Powerwall>/api/system_status/soe
# https://<ip-Powerwall>/api/meters/aggregates
# https://<ip-Powerwall>/api/site_info
# https://<ip-Powerwall>/api/sitemaster
# https://<ip-Powerwall>/api/powerwalls
# https://<ip-Powerwall>/api/networks
# https://<ip-Powerwall>/api/system/networks
# https://<ip-Powerwall>/api/operation
#
##
##

package FHEM::TeslaPowerwall2AC;

use strict;
use warnings;
use FHEM::Meta;
use GPUtils qw(GP_Import GP_Export);
use HttpUtils;
use Data::Dumper;

# try to use JSON::MaybeXS wrapper
#   for chance of better performance + open code
eval {
    require JSON::MaybeXS;
    import JSON::MaybeXS qw( decode_json encode_json );
    1;
};

if ($@) {
    $@ = undef;

    # try to use JSON wrapper
    #   for chance of better performance
    eval {

        # JSON preference order
        local $ENV{PERL_JSON_BACKEND} =
          'Cpanel::JSON::XS,JSON::XS,JSON::PP,JSON::backportPP'
          unless ( defined( $ENV{PERL_JSON_BACKEND} ) );

        require JSON;
        import JSON qw( decode_json encode_json );
        1;
    };

    if ($@) {
        $@ = undef;

        # In rare cases, Cpanel::JSON::XS may
        #   be installed but JSON|JSON::MaybeXS not ...
        eval {
            require Cpanel::JSON::XS;
            import Cpanel::JSON::XS qw(decode_json encode_json);
            1;
        };

        if ($@) {
            $@ = undef;

            # In rare cases, JSON::XS may
            #   be installed but JSON not ...
            eval {
                require JSON::XS;
                import JSON::XS qw(decode_json encode_json);
                1;
            };

            if ($@) {
                $@ = undef;

                # Fallback to built-in JSON which SHOULD
                #   be available since 5.014 ...
                eval {
                    require JSON::PP;
                    import JSON::PP qw(decode_json encode_json);
                    1;
                };

                if ($@) {
                    $@ = undef;

                    # Fallback to JSON::backportPP in really rare cases
                    require JSON::backportPP;
                    import JSON::backportPP qw(decode_json encode_json);
                    1;
                }
            }
        }
    }
}

## Import der FHEM Funktionen
#-- Run before package compilation
BEGIN {

    # Import from main context
    GP_Import(
        qw(
          readingsSingleUpdate
          readingsBulkUpdate
          readingsBulkUpdateIfChanged
          readingsBeginUpdate
          readingsEndUpdate
          setKeyValue
          getKeyValue
          getUniqueId
          CommandAttr
          defs
          Log3
          readingFnAttributes
          HttpUtils_NonblockingGet
          AttrVal
          ReadingsVal
          IsDisabled
          deviceEvents
          init_done
          gettimeofday
          InternalTimer
          RemoveInternalTimer)
    );
}

#-- Export to main context with different name
GP_Export(
    qw(
      Initialize
      Timer_GetData
      Write
      )
);

my %paths = (
    'statussoe'         => 'system_status/soe',
    'aggregates'        => 'meters/aggregates',
    'meterssite'        => 'meters/site',
    'meterssolar'       => 'meters/solar',
    'siteinfo'          => 'site_info',
    'sitename'          => 'site_info/site_name',
    'sitemaster'        => 'sitemaster',
    'powerwalls'        => 'powerwalls',
    'registration'      => 'customer/registration',
    'status'            => 'status',
    'gridstatus'        => 'system_status/grid_status',
);

my %cmdPaths = (
    'powerwallsstop'    => 'sitemaster/stop',
    'powerwallsrun'     => 'sitemaster/run',
);

sub Initialize {

    my $hash = shift;

    # Consumer
    $hash->{GetFn}    = \&Get;
    $hash->{SetFn}    = \&Set;
    $hash->{DefFn}    = \&Define;
    $hash->{UndefFn}  = \&Undef;
    $hash->{NotifyFn} = \&Notify;
    $hash->{RenameFn} = \&Rename;

    $hash->{AttrFn} = \&Attr;
    $hash->{AttrList} =
              'interval '
            . 'disable:1 '
            . 'devel:1 '
            . 'emailaddr '
            . $readingFnAttributes;
    $hash->{parseParams} = 1;

    return FHEM::Meta::InitMod( __FILE__, $hash );
}

sub Define {
    my $hash = shift // return;
    my $aArg = shift // return;    

    return $@ unless ( FHEM::Meta::SetInternals($hash) );
    use version 0.60; our $VERSION = FHEM::Meta::Get( $hash, 'version' );

    return 'too few parameters: define <name> TeslaPowerwall2AC <HOST>'
      if ( scalar( @{$aArg} ) != 3 );

    my $name = $aArg->[0];
    my $host = $aArg->[2];

    $hash->{HOST}        = $host;
    $hash->{INTERVAL}    = 300;
    $hash->{VERSION}     = version->parse($VERSION)->normal;
    $hash->{NOTIFYDEV}   = "global,$name";
    $hash->{actionQueue} = [];

    CommandAttr( undef, $name . ' room Tesla' )
      if ( AttrVal( $name, 'room', 'none' ) eq 'none' );
    Log3 $name, 3,
"TeslaPowerwall2AC ($name) - defined TeslaPowerwall2AC Device with Host $host and Interval $hash->{INTERVAL}";

    return undef;
}

sub Undef {
    my $hash    = shift;
    my $name    = shift;

    RemoveInternalTimer($hash);
    Log3 $name, 3, "TeslaPowerwall2AC ($name) - Device $name deleted";

    return undef;
}

sub Attr {
    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash = $defs{$name};

    if ( $attrName eq 'disable' ) {
        if ( $cmd eq 'set' and $attrVal eq '1' ) {
            RemoveInternalTimer($hash);
            readingsSingleUpdate( $hash, 'state', 'disabled', 1 );
            Log3 $name, 3, "TeslaPowerwall2AC ($name) - disabled";

        }
        elsif ( $cmd eq 'del' ) {
            Log3 $name, 3, "TeslaPowerwall2AC ($name) - enabled";
        }
    }

    if ( $attrName eq 'disabledForIntervals' ) {
        if ( $cmd eq 'set' ) {
            return
'check disabledForIntervals Syntax HH:MM-HH:MM or \'HH:MM-HH:MM HH:MM-HH:MM ...\''
              unless ( $attrVal =~ /^((\d{2}:\d{2})-(\d{2}:\d{2})\s?)+$/ );
            Log3 $name, 3, "TeslaPowerwall2AC ($name) - disabledForIntervals";
            readingsSingleUpdate( $hash, 'state', 'disabled', 1 );

        }
        elsif ( $cmd eq 'del' ) {
            Log3 $name, 3, "TeslaPowerwall2AC ($name) - enabled";
            readingsSingleUpdate( $hash, 'state', 'active', 1 );
        }
    }

    if ( $attrName eq 'interval' ) {
        if ( $cmd eq 'set' ) {
            if ( $attrVal < 60 ) {
                Log3 $name, 3,
"TeslaPowerwall2AC ($name) - interval too small, please use something >= 60 (sec), default is 300 (sec)";
                return
'interval too small, please use something >= 60 (sec), default is 300 (sec)';

            }
            else {
                RemoveInternalTimer($hash);
                $hash->{INTERVAL} = $attrVal;
                Log3 $name, 3,
                  "TeslaPowerwall2AC ($name) - set interval to $attrVal";
            }
        }
        elsif ( $cmd eq 'del' ) {
            RemoveInternalTimer($hash);
            $hash->{INTERVAL} = 300;
            Log3 $name, 3,
              "TeslaPowerwall2AC ($name) - set interval to default";
        }
    }

    return undef;
}

sub Notify {
    my $hash    = shift;
    my $dev     = shift;
    
    my $name    = $hash->{NAME};
    return if ( IsDisabled($name) );

    my $devname = $dev->{NAME};
    my $devtype = $dev->{TYPE};
    my $events  = deviceEvents( $dev, 1 );
    return if ( !$events );

    Timer_GetData($hash)
      if (
           ( grep /^INITIALIZED$/, @{$events}
          or grep /^ATTR.$name.emailaddr$/, @{$events}
          or grep /^ATTR.$name.interval$/, @{$events}
          or grep /^ATTR.$name.disable$/, @{$events}
          or grep /^DELETEATTR.$name.disable$/, @{$events}
          or grep /^DELETEATTR.$name.interval$/, @{$events}
          or grep /^DEFINED.$name$/, @{$events} )
        and $init_done
      );
    return;
}

sub Get {
    my $hash = shift // return;
    my $aArg = shift // return;

    my $name = shift @$aArg;
    my $cmd  = shift @$aArg // return qq{"get $name" needs at least one argument};
    my $arg;

    if ( $cmd eq 'statusSOE' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'aggregates' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'siteinfo' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'powerwalls' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'sitemaster' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'registration' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'status' ) {

        $arg = lc($cmd);

    }
    else {

        my $list = '';
        $list .=
'statusSOE:noArg aggregates:noArg siteinfo:noArg sitemaster:noArg powerwalls:noArg registration:noArg status:noArg'
  if(  AttrVal($name,'emailaddr','none') ne 'none'
    && defined(ReadPassword($hash, $name))
    && defined($hash->{TOKEN}) );

        return 'Unknown argument ' . $cmd . ', choose one of ' . $list;
    }

    return 'There are still path commands in the action queue'
      if ( defined( $hash->{actionQueue} )
        and scalar( @{ $hash->{actionQueue} } ) > 0 );

    unshift( @{ $hash->{actionQueue} }, $arg );
    Write($hash);

    return undef;
}

sub Set {
    my $hash = shift // return;
    my $aArg = shift // return;

    my $name = shift @$aArg;
    my $cmd  = shift @$aArg // return qq{"set $name" needs at least one argument};
    my $arg;

    if ( $cmd eq 'powerwalls' ) {
        $arg = lc( $cmd . $aArg->[0] );
    }
    elsif ( lc $cmd eq 'setpassword' ) {
        return "please set Attribut emailaddr first"
          if ( AttrVal( $name, 'emailaddr', 'none' ) eq 'none' );
        return "usage: $cmd <password>" if ( scalar( @{$aArg} ) != 1 );

        StorePassword( $hash, $name, $aArg->[0] );
        return Timer_GetData($hash);
    }
    elsif ( lc $cmd eq 'removepassword' ) {
        return "usage: $cmd" if ( scalar( @{$aArg} ) != 0 );

        DeletePassword($hash);
        return Timer_GetData($hash);
    }
    else {

        my $list = ( defined(ReadPassword($hash, $name)) ? 'removePassword:noArg ' : 'setPassword ');
        $list .= 'powerwalls:run,stop'
          if ( AttrVal( $name, 'devel', 0 ) == 1 );

        return 'Unknown argument ' . $cmd . ', choose one of ' . $list;
    }

    unshift( @{ $hash->{actionQueue} }, $arg );
    Write($hash);

    return undef;
}

sub Timer_GetData {
    my $hash = shift;
    my $name = $hash->{NAME};

    RemoveInternalTimer($hash);

    if ( defined( $hash->{actionQueue} )
        and scalar( @{ $hash->{actionQueue} } ) == 0 )
    {
        if ( !IsDisabled($name) ) {
            return readingsSingleUpdate( $hash, 'state',
              'please set Attribut emailaddr first', 1 )
                if ( AttrVal( $name, 'emailaddr', 'none' ) eq 'none' );
            return readingsSingleUpdate( $hash, 'state',
              'please set password first', 1 )
                if ( !defined( ReadPassword( $hash, $name ) ) );
        
            if ( !defined( $hash->{TOKEN}) ) {
                unshift( @{ $hash->{actionQueue} }, 'login' );
            }
            else {
                while ( my $obj = each %paths ) {
                    unshift( @{ $hash->{actionQueue} }, $obj );
                }
            }

            Write($hash);
        }
        else {
            return readingsSingleUpdate( $hash, 'state', 'disabled', 1 );
        }
    }

    InternalTimer( gettimeofday() + $hash->{INTERVAL},
        'TeslaPowerwall2AC_Timer_GetData', $hash );
    Log3 $name, 4,
      "TeslaPowerwall2AC ($name) - Call InternalTimer Timer_GetData";
}

sub Write {
    my $hash = shift;
    my $name = $hash->{NAME};

    my ( $uri, $method, $header, $data, $path ) =
      CreateUri( $hash, pop( @{ $hash->{actionQueue} } ) );

    readingsSingleUpdate(
        $hash,
        'state',
        'fetch data - '
          . scalar( @{ $hash->{actionQueue} } )
          . ' entries in the Queue',
        1
    );

    HttpUtils_NonblockingGet(
        {
            url       => 'https://' . $uri,
            timeout   => 5,
            method    => $method,
            data      => $data,
            header    => $header,
            hash      => $hash,
            setCmd    => $path,
            doTrigger => 1,
            callback  => \&ErrorHandling,
        }
    );

    Log3 $name, 4, "TeslaPowerwall2AC ($name) - Send with URI: https://$uri";
}

sub ErrorHandling {
    my $param   = shift;
    my $err     = shift;
    my $data    = shift;
    
    my $hash    = $param->{hash};
    my $name    = $hash->{NAME};

    ### Begin Error Handling

    if ( defined($err) ) {
        if ( $err ne '' ) {

            readingsBeginUpdate($hash);
            readingsBulkUpdate( $hash, 'state',            $err, 1 );
            readingsBulkUpdate( $hash, 'lastRequestError', $err, 1 );
            readingsEndUpdate( $hash, 1 );

            Log3 $name, 3, "TeslaPowerwall2AC ($name) - RequestERROR: $err";

            $hash->{actionQueue} = [];
            return;
        }
    }

    if ( $data eq '' and exists( $param->{code} ) && $param->{code} != 200 ) {

        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, 'state', $param->{code}, 1 );

        readingsBulkUpdate( $hash, 'lastRequestError', $param->{code}, 1 );

        Log3 $name, 3,
          "TeslaPowerwall2AC ($name) - RequestERROR: " . $param->{code};

        readingsEndUpdate( $hash, 1 );

        Log3 $name, 5,
            "TeslaPowerwall2AC ($name) - RequestERROR: received http code "
          . $param->{code}
          . " without any data after requesting";

        $hash->{actionQueue} = [];
        return;
    }

    if ( $data =~ m#{"code":(\d+),"error":"(.+)","message":"(.+)"}$# ) {

        readingsBeginUpdate($hash);

        readingsBulkUpdate( $hash, 'state', $1, 1 );
        readingsBulkUpdate(
            $hash,
            'lastRequestError',
            'Path: '
              . $param->{setCmd} . ' '
              . $1
              . ' - Error: '
              . $2
              . ' Messages: '
              . $3,
            1
        );

        readingsEndUpdate( $hash, 1 );
    }
    #### End Error Handling

    InternalTimer( gettimeofday() + 3, 'TeslaPowerwall2AC_Write', $hash )
      if ( defined( $hash->{actionQueue} )
        and scalar( @{ $hash->{actionQueue} } ) > 0 );

    Log3 $name, 4, "TeslaPowerwall2AC ($name) - Recieve JSON data: $data";

    ResponseProcessing( $hash, $param->{setCmd}, $data );
}

sub ResponseProcessing {
    my $hash    = shift;
    my $path    = shift;
    my $json    = shift;

    my $name    = $hash->{NAME};
    my $decode_json;
    my $readings;

    $decode_json = eval { decode_json($json) };
    if ($@) {
        Log3 $name, 4, "TeslaPowerwall2AC ($name) - error while request: $@";
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, 'JSON Error', $@ );
        readingsBulkUpdate( $hash, 'state',      'JSON error' );
        readingsEndUpdate( $hash, 1 );
        return;
    }

    return
      if (  ref($decode_json) eq 'HASH'
        and defined( $decode_json->{error} )
        and $decode_json->{error}
        and defined( $decode_json->{code} )
        and $decode_json->{code} );

    #### Verarbeitung der Readings zum passenden Path

    if ( $path eq 'aggregates' ) {
        $readings = ReadingsProcessing_Aggregates( $hash, $decode_json );
    }
    elsif ( $path eq 'powerwalls' ) {
        $readings = ReadingsProcessing_Powerwalls( $hash, $decode_json );
    }
    elsif ( $path eq 'login' ) {
        $hash->{TOKEN} = $decode_json->{token};
        return Timer_GetData($hash);
    }
    elsif ( $path eq 'meterssite' ) {
        $readings = ReadingsProcessing_Meters_Site( $hash, $decode_json );
    }
    elsif ( $path eq 'meterssolar' ) {
        $readings = ReadingsProcessing_Meters_Solar( $hash, $decode_json );
    }
    else {
        $readings = $decode_json;
    }

    WriteReadings( $hash, $path, $readings );
}

sub WriteReadings {
    my $hash        = shift;
    my $path        = shift;
    my $readings    = shift;

    my $name        = $hash->{NAME};

    Log3 $name, 4, "TeslaPowerwall2AC ($name) - Write Readings";

    readingsBeginUpdate($hash);
    while ( my ( $r, $v ) = each %{$readings} ) {
        readingsBulkUpdate( $hash, $path . '-' . $r, $v );
    }

    readingsBulkUpdate( $hash, 'batteryLevel',
        sprintf( "%.1f", $readings->{percentage} ) )
      if ( defined( $readings->{percentage} ) );
    readingsBulkUpdate(
        $hash,
        'batteryPower',
        sprintf(
            "%.1f",
            (
                ReadingsVal( $name, 'siteinfo-nominal_system_energy_kWh', 0 ) /
                  100
            ) * ReadingsVal( $name, 'statussoe-percentage', 0 )
        )
    );

    readingsBulkUpdateIfChanged( $hash, 'actionQueue',
        scalar( @{ $hash->{actionQueue} } ) . ' entries in the Queue' );
    readingsBulkUpdateIfChanged(
        $hash, 'state',
        (
            defined( $hash->{actionQueue} )
              and scalar( @{ $hash->{actionQueue} } ) == 0
            ? 'ready'
            : 'fetch data - '
              . scalar( @{ $hash->{actionQueue} } )
              . ' paths in actionQueue'
        )
    );

    readingsEndUpdate( $hash, 1 );
}

sub ReadingsProcessing_Aggregates {
    my $hash        = shift;
    my $decode_json = shift;
    
    my $name        = $hash->{NAME};
    my %readings;

    if ( ref($decode_json) eq 'HASH' ) {
        while ( my $obj = each %{$decode_json} ) {
            while ( my ( $r, $v ) = each %{ $decode_json->{$obj} } ) {
                $readings{ $obj . '-' . $r } = $v;
            }
        }
    }
    else {
        $readings{'error'} = 'aggregates response is not a Hash';
    }

    return \%readings;
}

sub ReadingsProcessing_Powerwalls {
    my $hash        = shift;
    my $decode_json = shift;
    
    my $name        = $hash->{NAME};
    my %readings;

    if ( ref( $decode_json->{powerwalls} ) eq 'ARRAY'
      && scalar( @{ $decode_json->{powerwalls} } ) > 0 )
    {
        my $i = 0;
        for my $powerwall ( @{ $decode_json->{powerwalls} } ) {
            if ( ref($powerwall) eq 'HASH' ) {

                while ( my ( $r, $v ) = each %{$powerwall} ) {
                    $readings{ 'wall_' . $i . '_' . $r } = $v
                      if ( ref($v) ne 'HASH' );

#                     if ( ref($v) eq 'HASH' ) {
#                         while ( my ( $s, $ts ) = each %{$v} ) {
#                             if ( ref( $ts ) eq 'ARRAY'
#                               && scalar( @{ $ts } ) > 0 )
#                             {
#                                 my $j = 0;
#                                 for my $t ( @{ $ts } ) {
#                                     $readings{ 'wall_' . $i . '_' . $r . '_' . $s . '_' . $j } = $t;
#                                     $j++;
#                                 }
#                             }
#                         }
#                     }
                }

                $i++;
            }
        }

        $readings{'numberOfWalls'} = $i;
    }
    else {
        $readings{'error'} = 'aggregates response is not a Array';
    }

    return \%readings;
}

sub ReadingsProcessing_Site_Info {
    my $hash        = shift;
    my $decode_json = shift;

    my $name        = $hash->{NAME};
    my %readings;

    if ( ref($decode_json) eq 'HASH' ) {
        while ( my $obj = each %{$decode_json} ) {
            while ( my ( $r, $v ) = each %{ $decode_json->{$obj} } ) {
                $readings{ $obj . '-' . $r } = $v;
            }
        }
    }
    else {
        $readings{'error'} = 'siteinfo response is not a Hash';
    }

    return \%readings;
}

sub ReadingsProcessing_Meters_Site {
    my $hash        = shift;
    my $decode_json = shift;
    
    my $name        = $hash->{NAME};
    my %readings;

    if ( ref($decode_json) eq 'ARRAY'
        and scalar( @{$decode_json} ) > 0 )
    {
        if ( ref( $decode_json->[0] ) eq 'HASH' ) {
            while ( my $obj = each %{ $decode_json->[0] } ) {
                if (   ref( $decode_json->[0]->{$obj} ) eq 'ARRAY'
                    || ref( $decode_json->[0]->{$obj} ) eq 'HASH' )
                {
                    if ( ref( $decode_json->[0]->{$obj} ) eq 'HASH' ) {
                        while ( my ( $r, $v ) =
                            each %{ $decode_json->[0]->{$obj} } )
                        {
                            if ( ref($v) ne 'HASH' ) {
                                $readings{ $obj . '-' . $r } = $v;
                            }
                            else {
                                while ( my ( $r2, $v2 ) =
                                    each %{ $decode_json->[0]->{$obj}->{$r} } )
                                {
                                    $readings{ $obj . '-' . $r . '-' . $r2 } =
                                      $v2;
                                }
                            }
                        }
                    }
                    elsif ( ref( $decode_json->[0]->{$obj} ) eq 'ARRAY' ) {

                    }
                }
                else {
                    $readings{$obj} = $decode_json->[0]->{$obj};
                }
            }
        }
    }
    else {
        $readings{'error'} = 'metes site response is not a Array';
    }

    return \%readings;
}

sub ReadingsProcessing_Meters_Solar {
    my $hash        = shift;
    my $decode_json = shift;

    my $name        = $hash->{NAME};
    my %readings;

    if ( ref($decode_json) eq 'ARRAY'
        and scalar( @{$decode_json} ) > 0 )
    {
        if ( ref( $decode_json->[0] ) eq 'HASH' ) {
            while ( my $obj = each %{ $decode_json->[0] } ) {
                if (   ref( $decode_json->[0]->{$obj} ) eq 'ARRAY'
                    || ref( $decode_json->[0]->{$obj} ) eq 'HASH' )
                {
                    if ( ref( $decode_json->[0]->{$obj} ) eq 'HASH' ) {
                        while ( my ( $r, $v ) =
                            each %{ $decode_json->[0]->{$obj} } )
                        {
                            if ( ref($v) ne 'HASH' ) {
                                $readings{ $obj . '-' . $r } = $v;
                            }
                            else {
                                while ( my ( $r2, $v2 ) =
                                    each %{ $decode_json->[0]->{$obj}->{$r} } )
                                {
                                    $readings{ $obj . '-' . $r . '-' . $r2 } =
                                      $v2;
                                }
                            }
                        }
                    }
                    elsif ( ref( $decode_json->[0]->{$obj} ) eq 'ARRAY' ) {

                    }
                }
                else {
                    $readings{$obj} = $decode_json->[0]->{$obj};
                }
            }
        }
    }
    else {
        $readings{'error'} = 'metes solar response is not a Array';
    }

    return \%readings;
}

sub CreateUri {
    my $hash        = shift;
    my $path        = shift;

    my $name        = $hash->{NAME};
    my $host        = $hash->{HOST};
    my $header      = ( defined($hash->{TOKEN}) ? 'Cookie: AuthCookie=' . $hash->{TOKEN} : undef );
    my $method      = 'GET';
    my $uri         = ( $path ne 'login' ? $host . '/api/' . $paths{$path} : $host . '/api/login/Basic' );
    my $data;


    if ( $path eq 'login' ) {
        $method     = 'POST';
        $header     = 'Content-Type: application/json';
        $data       = 
              '{"username":"customer","password":"'
            . ReadPassword( $hash, $name )
            . '","email":"'
            . AttrVal($name,'emailaddr','test@test.de')
            . '","force_sm_off":false}'
    }
    elsif ( $path eq 'powerwallsstop'
         || $path eq 'powerwallsruns' )
    {
        $uri        = $host . '/api/' . $cmdPaths{$path};
    }

    return ( $uri, $method, $header, $data, $path );
}

sub StorePassword {
    my $hash     = shift;
    my $name     = shift;
    my $password = shift;

    my $index   = $hash->{TYPE} . "_" . $name . "_passwd";
    my $key     = getUniqueId() . $index;
    my $enc_pwd = "";

    if ( eval "use Digest::MD5;1" ) {

        $key = Digest::MD5::md5_hex( unpack "H*", $key );
        $key .= Digest::MD5::md5_hex($key);
    }

    for my $char ( split //, $password ) {

        my $encode = chop($key);
        $enc_pwd .= sprintf( "%.2x", ord($char) ^ ord($encode) );
        $key = $encode . $key;
    }

    my $err = setKeyValue( $index, $enc_pwd );
    return "error while saving the password - $err" if ( defined($err) );

    return "password successfully saved";
}

sub ReadPassword {
    my $hash = shift;
    my $name = shift;

    my $index = $hash->{TYPE} . "_" . $name . "_passwd";
    my $key   = getUniqueId() . $index;
    my ( $password, $err );

    Log3 $name, 4, "TeslaPowerwall2AC ($name) - Read password from file";

    ( $err, $password ) = getKeyValue($index);

    if ( defined($err) ) {

        Log3 $name, 3,
"TeslaPowerwall2AC ($name) - unable to read password from file: $err";
        return undef;

    }

    if ( defined($password) ) {
        if ( eval "use Digest::MD5;1" ) {

            $key = Digest::MD5::md5_hex( unpack "H*", $key );
            $key .= Digest::MD5::md5_hex($key);
        }

        my $dec_pwd = '';

        for my $char ( map { pack( 'C', hex($_) ) } ( $password =~ /(..)/g ) ) {

            my $decode = chop($key);
            $dec_pwd .= chr( ord($char) ^ ord($decode) );
            $key = $decode . $key;
        }

        return $dec_pwd;

    }
    else {

        Log3 $name, 3, "TeslaPowerwall2AC ($name) - No password in file";
        return undef;
    }

    return;
}



sub DeletePassword {
    my $hash    = shift;

    setKeyValue( $hash->{TYPE} . "_" . $hash->{NAME} . "_passwd", undef );

    return;
}

sub Rename {
    my $new     = shift;
    my $old     = shift;

    my $hash    = $defs{$new};

    StorePassword( $hash, $new, ReadPassword( $hash, $old ) );
    setKeyValue( $hash->{TYPE} . "_" . $old . "_passwd", undef );

    return;
}

1;

=pod

=item device
=item summary       Modul to retrieves data from a Tesla Powerwall 2AC
=item summary_DE 

=begin html

<a name="TeslaPowerwall2AC"></a>
<h3>Tesla Powerwall 2 AC</h3>
<ul>
    <u><b>TeslaPowerwall2AC - Retrieves data from a Tesla Powerwall 2AC System</b></u>
    <br>
    With this module it is possible to read the data from a Tesla Powerwall 2AC and to set it as reading.
    <br><br>
    <a name="TeslaPowerwall2ACdefine"></a>
    <b>Define</b>
    <ul><br>
        <code>define &lt;name&gt; TeslaPowerwall2AC &lt;HOST&gt;</code>
    <br><br>
    Example:
    <ul><br>
        <code>define myPowerWall TeslaPowerwall2AC 192.168.1.34</code><br>
    </ul>
    <br>
    This statement creates a Device with the name myPowerWall and the Host IP 192.168.1.34.<br>
    After the device has been created, the current data of Powerwall is automatically read from the device.
    </ul>
    <br><br>
    <a name="TeslaPowerwall2ACreadings"></a>
    <b>Readings</b>
    <ul>
        <li>actionQueue     - information about the entries in the action queue</li>
        <li>aggregates-*    - readings of the /api/meters/aggregates response</li>
        <li>batteryLevel    - battery level in percent</li>
        <li>batteryPower    - battery capacity in kWh</li>
        <li>powerwalls-*    - readings of the /api/powerwalls response</li>
        <li>registration-*  - readings of the /api/customer/registration response</li>
        <li>siteinfo-*      - readings of the /api/site_info response</li>
        <li>sitemaster-*    - readings of the /api/sitemaster response</li>
        <li>state           - information about internel modul processes</li>
        <li>status-*        - readings of the /api/status response</li>
        <li>statussoe-*     - readings of the /api/system_status/soe response</li>
        <li>setPassword     - write password encrypted to password file</li>
        <li>removePassword  - remove password from password file</li>
    </ul>
    <a name="TeslaPowerwall2ACget"></a>
    <b>get</b>
    <ul>
        <li>aggregates      - fetch data from url path /api/meters/aggregates</li>
        <li>powerwalls      - fetch data from url path /api/powerwalls</li>
        <li>registration    - fetch data from url path /api/customer/registration</li>
        <li>siteinfo        - fetch data from url path /api/site_info</li>
        <li>sitemaster      - fetch data from url path /api/sitemaster</li>
        <li>status          - fetch data from url path /api/status</li>
        <li>statussoe       - fetch data from url path /api/system_status/soe</li>
    </ul>
    <a name="TeslaPowerwall2ACattribute"></a>
    <b>Attribute</b>
    <ul>
        <li>interval - interval in seconds for automatically fetch data (default 300)</li>
        <li>emailaddr - emailadress to get cookie token</li>
    </ul>
</ul>

=end html
=begin html_DE

<a name="TeslaPowerwall2AC"></a>
<h3>Tesla Powerwall 2 AC</h3>

=end html_DE

=for :application/json;q=META.json 46_TeslaPowerwall2AC.pm
{
  "abstract": "Modul to retrieves data from a Tesla Powerwall 2AC",
  "x_lang": {
    "de": {
      "abstract": ""
    }
  },
  "keywords": [
    "fhem-mod-device",
    "fhem-core",
    "Power",
    "Tesla",
    "AC",
    "Powerwall",
    "Control"
  ],
  "release_status": "stable",
  "license": "GPL_2",
  "version": "v1.0.5",
  "author": [
    "Marko Oldenburg <leongaultier@gmail.com>"
  ],
  "x_fhem_maintainer": [
    "CoolTux"
  ],
  "x_fhem_maintainer_github": [
    "LeonGaultier"
  ],
  "prereqs": {
    "runtime": {
      "requires": {
        "FHEM": 5.00918799,
        "perl": 5.016, 
        "Meta": 0,
        "JSON": 0,
        "Date::Parse": 0
      },
      "recommends": {
      },
      "suggests": {
      }
    }
  }
}
=end :application/json;q=META.json

=cut
