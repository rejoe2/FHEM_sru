#########################################################################
# $Id: 98_vitoconnect.pm 29740 2025-05-07 Beta-User $
# fhem Modul für Viessmann API. Based on investigation of "thetrueavatar"
# (https://github.com/thetrueavatar/Viessmann-Api)
#
#     This file is part of fhem.
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#

#   https://wiki.fhem.de/wiki/DevelopmentModuleAPI
#   https://forum.fhem.de/index.php/topic,93664.0.html
#   https://www.viessmann-community.com/t5/Announcements/Important-adjustment-in-IoT-features-Split-heating-circuits-and/td-p/281527
#   https://forum.fhem.de/index.php/topic,93664.msg1257651.html#msg1257651
#   https://www.viessmann-community.com/t5/Getting-started-programming-with/Syntax-for-setting-a-value/td-p/374222
#   https://forum.fhem.de/index.php?msg=1326376


package main;
use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use JSON;
#use JSON::XS qw( decode_json ); #Could be faster, but caused error for Schlimbo PERL WARNING: Prototype mismatch: sub main::decode_json ($;$$) vs ($) at /usr/local/lib/perl5/5.36.3/Exporter.pm line 63.
use HttpUtils;
#use Encode qw(decode encode);
use Data::Dumper;
use Path::Tiny;
use DateTime;
use Time::Piece;
use Time::Seconds;

eval "use FHEM::Meta;1"                   or my $modMetaAbsent = 1;                  ## no critic 'eval'
use FHEM::SynoModules::SMUtils qw (
                                   moduleVersion
                                  );                                                 # Hilfsroutinen Modul

my %vNotesIntern = (
  "0.8.7"  => "09.03.2025  Fix return value when using SVN or Roger",
  "0.8.6"  => "24.02.2025  Adapt schedule data before sending",
  "0.8.5"  => "24.02.2025  fix error when calling setter from FHEMWEB",
  "0.8.4"  => "24.02.2025  also order mode, start, end, position in schedule",
  "0.8.3"  => "23.02.2025  fix order of days for type schedule readings",
  "0.8.2"  => "22.02.2025  improved State reading in case of unknown error",
  "0.8.1"  => "20.02.2025  replace U+FFFD (unknown character with [VUC] see https://forum.fhem.de/index.php?msg=1334504, also fill reason in error case from extended payload",
  "0.8.0"  => "18.02.2025  enhanced error mapping now also language dependent, closing of file_handles, removed JSON::XS",
  "0.7.8"  => "17.02.2025  fixed undef warning thanks cnkru",
  "0.7.7"  => "17.02.2025  introduced clearMappedErrors",
  "0.7.6"  => "17.02.2025  removed usage of html libraries",
  "0.7.5"  => "16.02.2025  Get mapped error codes and store them in readings",
  "0.7.4"  => "16.02.2025  Removed Unknow attr vitoconnect, small bugfix DeleteKeyValue",
  "0.7.3"  => "16.02.2025  Write *.err file in case of error. Fixed DeleteKeyValue thanks Schlimbo",
  "0.7.2"  => "07.02.2025  Attr logging improved",
  "0.7.1"  => "07.02.2025  Code cleanups",
  "0.7.0"  => "06.02.2025  vitoconnect_installationID checked now for at least length 2, see https://forum.fhem.de/index.php?msg=1333072, error handling when setting attributs automatic introduced",
  "0.6.3"  => "04.02.2025  Small bug fixes, removed warnings",
  "0.6.2"  => "28.01.2025  Very small bugfixes ",
  "0.6.1"  => "28.01.2025  Rework of module documentation",
  "0.6.0"  => "23.01.2025  Total rebuild of initialization and gw handling. In case of more than one installation or gw you have to set it via".
                          "selectDevice in the set of the device. The attributes vitoconnect_serial and vitoconnect_installationID will be populated".
                          "handling of getting installation and serial changed. StoredValues are now deleted. Other fixes and developments",
  "0.5.0"  => "02.01.2025  Added attribute installationID, in case you use two installations, see https://forum.fhem.de/index.php?msg=1329165",
  "0.4.2"  => "31.12.2024  Small fix for Vitoladens 300C, heating.circuits.0.operating.programs.comfort",
  "0.4.1"  => "30.12.2024  Bug fixes, fixed Releasenotes, changed debugging texts and messages in Set_New",
  "0.4.0"  => "28.12.2024  Fixed setNew to work again automatically in case of one serial in gateways,".
                           "for more than one serial you have to define the serial you want to use",
  "0.3.2"  => "27.12.2024  Set in case of activate and deactivate request the active value of the reading",
  "0.3.1"  => "19.12.2024  New attribute vitoconnect_disable_raw_readings",
  "0.3.0"  => "18.12.2024  Fix setter new for cases where more than one gateway is actively pulled in 2 devices.",
  "0.2.1"  => "16.12.2024  German and English texts in UI",
  "0.2.0"  => "14.12.2024  FVersion introduced, a bit of code beautifying".
                          "sort keys per reading to ensure power readings are in the right order, day before dayvalue",
  "0.1.1"  => "12.12.2024  In case of more than one Gateway only allow Set_New if serial is provided. ".
                          "Get Object and Hash in Array readings. E.g. device.messages.errors.raw. ".
                          "In case of expired token (every hour) do not do uncessary gateway calls, just get the new token. ".
                          "This will safe API calls and reduce the API overhead. ",
  "0.1.0"  => "12.12.2024  first release with Version. "
);

my $vitoconnect_client_secret = '2e21faa1-db2c-4d0b-a10f-575fd372bc8c-575fd372bc8c';
my $vitoconnect_callback_uri  = 'http://localhost:4200/';
my $vitoconnect_baseURL       = 'viessmann-climatesolutions.com';
my $vitoconnect_iotURL_V1     = "https://api.$vitoconnect_baseURL/iot/v2/equipment/";
my $vitoconnect_iotURL_V2     = "https://api.$vitoconnect_baseURL/iot/v2/features/";
my $vitoconnect_errorURL_V3   = "https://api.$vitoconnect_baseURL/service-documents/v3/error-database";
my $vitoconnect_authorizeURL  = "https://iam.$vitoconnect_baseURL/idp/v2/authorize";
my $vitoconnect_tokenURL      = "https://iam.$vitoconnect_baseURL/idp/v2/token";



#####################################################################################################################
# Modul initialisieren und Namen zusätzlicher Funktionen bekannt geben
#####################################################################################################################
sub vitoconnect_Initialize {
    my $hash = shift // return;
    $hash->{DefFn}    = \&vitoconnect_Define;    # wird beim 'define' eines Gerätes aufgerufen
    $hash->{UndefFn}  = \&vitoconnect_Undef;     # # wird beim Löschen einer Geräteinstanz aufgerufen
    $hash->{DeleteFn} = \&vitoconnect_DeleteKeyValue;
    $hash->{NotifyFn} = \&vitoconnect_Notify;    # confFile changed?
    $hash->{SetFn}    = \&vitoconnect_Set;       # set-Befehle
    $hash->{GetFn}    = \&vitoconnect_Get;       # get-Befehle
    $hash->{AttrFn}   = \&vitoconnect_Attr;      # Attribute setzen/ändern/löschen
    $hash->{ReadFn}   = \&vitoconnect_Read;
    $hash->{RenameFn} = \&vitoconnect_Rename;

    $hash->{AttrList} =
        "disable:0,1 "
      . "vitoconnect_raw_readings:0,1,svn "             # Liefert nur die raw readings und verhindert das mappen wenn auf 1 gesetzt; svn-Mapping, wenn auf svn gesetzt
      . "vitoconnect_disable_raw_readings:0,1 "         # Wird ein mapping verwendet können die weiteren RAW Readings ausgeblendet werden
      . "vitoconnect_gw_readings:0,1 "                  # Schreibt die GW readings als Reading ins Device
      . "vitoconnect_actions_active:0,1 "
      . "vitoconnect_device:0,1 "                       # Hier kann Device 0 oder 1 angesprochen worden, default ist 0 und ich habe keinen GW mit Device 1
      . "vitoconnect_serial:textField-long "            # Legt fest welcher Gateway abgefragt werden soll, wenn nicht gesetzt werden alle abgefragt
      . "vitoconnect_installationID:textField-long "    # Legt fest welche Installation abgefragt werden soll, muss zur serial passen
      . "vitoconnect_timeout:selectnumbers,10,1.0,30,0,lin "
      . 'weekprofile confFile '
      . $readingFnAttributes;

      eval { FHEM::Meta::InitMod( __FILE__, $hash ) };     ## no critic 'eval'
    return;
}


#####################################################################################################################
# wird beim 'define' eines Gerätes aufgerufen
#####################################################################################################################
sub vitoconnect_Define {
    my ( $hash, $def ) = @_;
    my $name  = $hash->{NAME};
    my $type  = $hash->{TYPE};
    
    my $params = {
      hash        => $hash,
      name        => $name,
      type        => $type,
      notes       => \%vNotesIntern,
      useAPI      => 0,
      useSMUtils  => 1,
      useErrCodes => 0,
      useCTZ      => 0,
    };

    use version 0.77; our $VERSION = moduleVersion ($params);                                              # Versionsinformationen setzen
    delete $params->{hash};
        
    my($unnamed, $named) = parseParams($def);
    #parseParams: my ( $hash, $a, $h ) = @_;
    shift @{$unnamed}; # delete name from list
    shift @{$unnamed}; # delete TYPE from list
    
    setNotifyDev($hash, 'global');
    
    if (defined $named->{IODev} && defined $named->{subset}) { # client mode definition.
        $hash->{SERVER} = $named->{IODev};
        $hash->{subset} = $named->{subset};
        RemoveInternalTimer($hash);
        if (!$init_done) {
            ; # we will have to initialze client mode as well lateron...
            InternalTimer( gettimeofday() + 90, \&vitoconnect_Client_Register_Server, $hash, 1 );    # if server does not exists maybe it got deleted, recheck every 30 seconds if it reappears
            return;
        }
        
        #circuits.0 - circuits.3, dhw, fuelCell, solar
        return "choose one of circuits.0 - circuits.3, dhw, fuelCell or solar as subset!" if $named->{subset} !~ m{\A(circuits.[0-3]|dhw|fuelCell|solar)\z}x;
        return "IODev no valid master vitoconnect device!" if !defined $defs{$named->{IODev}} || InternalVal($named->{IODev},'TYPE','unknown') ne 'vitoconnect' || !defined InternalVal($named->{IODev},'apiKey',undef);
        return vitoconnect_Client_Register_Server($hash);
    }

    my $user = $named->{user} // shift @{$unnamed} // return 'no user provided!';
    $hash->{user}            = $user;
    my $interval= $named->{interval} // pop @{$unnamed} // 300;
    return 'no valid interval provided!' if !defined $interval || !looks_like_number($interval);
    $hash->{interval} = $interval;
    
    $hash->{counter}         = 0;
    $hash->{timeout}         = 15;
    $hash->{'.access_token'} = '';
    $hash->{devices}         = []; 
    $hash->{Redirect_URI}    = $vitoconnect_callback_uri;

    #$named->{password} // shift @{$unnamed};
    my $isiwebpasswd = vitoconnect_ReadKeyValue($name,'passwd');    # verschlüsseltes Kennwort auslesen
    if ($isiwebpasswd eq '')        {   # Kennwort (noch) nicht gespeichert
        $isiwebpasswd = $named->{password} // shift @{$unnamed};
        if (defined $isiwebpasswd) {
            my $err = vitoconnect_StoreKeyValue($name,'passwd',$isiwebpasswd);  # Kennwort verschlüsselt speichern
            return $err if ($err);
        }
    }
    else                            {   # Kennwort schon gespeichert
        Log3($name,4,$name." - Passwort war bereits gespeichert");
    }
    $hash->{DEF} = "user=$user interval=$interval";
    if (defined $named->{apiKey}) {
        my $err = vitoconnect_StoreKeyValue($name,'apiKey',$named->{apiKey});  # Kennwort verschlüsselt speichern
        return $err if ($err);
    }
    $hash->{apiKey} = vitoconnect_ReadKeyValue($name,'apiKey');         # verschlüsselten apiKey auslesen
    RemoveInternalTimer($hash); # Timer löschen, z.b. bei intervall change
    InternalTimer(gettimeofday() + 10,'vitoconnect_GetUpdate',$hash);   # nach 10s
    return;
}

sub vitoconnect_Client_Register_Server {
    my $hash = shift // return;
    return if !defined $hash->{SERVER};
    my $name   = $hash->{NAME} // return;
    my $server = $hash->{SERVER};
    if ( !defined $defs{$server} ) {
        InternalTimer( gettimeofday() + 30, \&vitoconnect_Client_Register_Server, $hash, 1 );    # if server does not exists maybe it got deleted, recheck every 30 seconds if it reappears
        return;
    }
    #$server = $defs{$server};               # get the server hash
    #Snapcast_getStatus($server);
    return;
}

#####################################################################################################################
# wird beim Löschen einer Geräteinstanz aufgerufen
#####################################################################################################################
sub vitoconnect_Undef {
    my ($hash,$arg ) = @_;      # Übergabe-Parameter
    RemoveInternalTimer($hash); # Timer löschen
    return;
}


#####################################################################################################################
# bisher kein 'get' implementiert
#####################################################################################################################
sub vitoconnect_Get {
    my ($hash,$name,$opt,@args ) = @_;  # Übergabe-Parameter
    return "get ".$name." needs at least one argument" unless (defined($opt) );
    return;
}


#####################################################################################################################
# Implementierung set-Befehle
#####################################################################################################################
sub vitoconnect_Set {
    my ($hash,$name,$opt,@args ) = @_;  # Übergabe-Parameter
    
    # Hier richtig?
    return "set $name needs at least one argument" if !defined $opt;
    
    return $hash->{'.sets'} if $opt eq '?' && defined $hash->{'.sets'}; # return value for getAllSets()
    # Standard Parameter setzen
    
    if ($opt eq 'clearReadings' )                    {   # set <name> clearReadings: clear all readings immeadiatlely
        AnalyzeCommand($hash,"deletereading $name .*");
        return;
    }

    my $val = "unknown value $opt, choose one of update:noArg clearReadings:noArg password apiKey logResponseOnce:noArg clearMappedErrors:noArg weekprofile ";
    #Log(5,$name.", -vitoconnect_Set started: ". $opt); #debug
    
    #client modules...
    if ( defined $hash->{SERVER} ) {
        my $serverhash = $defs{$hash->{SERVER}} // return;
        $val = "unknown value $opt, choose one of clearReadings:noArg weekprofile ";
        
        if ( !defined $hash->{'.sets'} ) {
            my $commands = getAllSets($hash->{SERVER});
            for my $commnd ( split m{\s+}x, $commands ) {
                my ($cmnd, $opts) = split m{:}x, $commnd;
                if ( defined $hash->{helper} && defined $hash->{helper}->{mappings} && defined $hash->{helper}->{mappings}->{$cmnd} ) {
                    #$hash->{helper}->{sets}->{$cmnd} = $hash->{helper}->{mappings}->{$cmnd};
                    $hash->{helper}->{sets}->{$hash->{helper}->{mappings}->{$cmnd}} = $cmnd;
                    $val .= defined $opts ? "$hash->{helper}->{mappings}->{$cmnd}:$opts " : "$hash->{helper}->{mappings}->{$cmnd} ";
                } elsif ( $cmnd =~ m{$hash->{subset}} ) {
                    $val .= defined $opts ? "${cmnd}:$opts " : "${cmnd} ";
                }
            }
            $hash->{'.sets'} = $val;
        }
        
        if ( defined $hash->{helper} && defined $hash->{helper}->{sets} ) {
            $opt = $hash->{helper}->{sets}->{$opt}  // $opt;
        }
        push @args, $hash->{subset} if $opt eq 'weekprofile';

        return vitoconnect_Set( $serverhash,$hash->{SERVER},$opt,@args );
    }
    
    # Setter für die Geräteauswahl dynamisch erstellen  
    #Log3($name,5,$name." - Set devices: ".$hash->{devices});
    if (defined $hash->{devices} && ref($hash->{devices}) eq 'HASH' && keys %{$hash->{devices}} > 0) {
        my @device_serials = keys %{$hash->{devices}};
        $val .= " selectDevice:" . join(",", @device_serials);
    } else {
        $val .= ' selectDevice:noArg'
    }
    $val .= ' ';
    #Log3($name,5,$name." - Set val: $val, Set Opt: $opt");
    
    
    # Setter für Device Werte rufen
    my $more_sets = vitoconnect_Set_New ($hash,$name,$opt,@args);
    
    # Check if val was returned or action executed with return;
    return if !defined $more_sets;  #sucessfull set command in sub

    $val .= $more_sets;
    $hash->{'.sets'} = $val if !defined $hash->{'.sets'};
    return $val if $opt eq '?'; # return value for getAllSet()

    if  ($opt eq 'update')                            {   # set <name> update: update readings immeadiatlely
        vitoconnect_GetUpdate($hash);                       # neue Abfrage starten
        return;
    }
    if ($opt eq 'logResponseOnce' )                  {   # set <name> logResponseOnce: dumps the json response of Viessmann server to entities.json, gw.json, actions.json in FHEM log directory
        $hash->{'.logResponseOnce'} = 1;                    # in 'Internals' merken
        vitoconnect_getCode($hash);                         # Werte für: Access-Token, Install-ID, Gateway anfragen
        return;
    }
    
    if ($opt eq 'password' )                         {   # set <name> password: store password in key store
        my $err = vitoconnect_StoreKeyValue($name,'passwd',$args[0]);   # Kennwort verschlüsselt speichern
        return $err if ($err);
        vitoconnect_getCode($hash);                         # Werte für: Access-Token, Install-ID, Gateway anfragen
        return;
    }
    if ($opt eq 'apiKey' )                           {   # set <name> apiKey: bisher keine Beschreibung
        $hash->{apiKey} = $args[0];
        my $err = vitoconnect_StoreKeyValue($name,'apiKey',$args[0]);   # apiKey verschlüsselt speichern
        return $err if ($err);
        vitoconnect_getCode($hash);                         # Werte für: Access-Token, Install-ID, Gateway anfragen
        return;
    }
    if ($opt eq 'selectDevice' )                           {   # set <name> selectDevice: Bei mehreren Devices eines auswählen
        Log3($name,4,$name." - Set selectedDevice serial: ".$args[0]);
        if (defined $args[0] && $args[0] ne '') {
            my $serial = $args[0];
            my %devices = %{ $hash->{devices} };
            if (exists $devices{$serial}) {
              my $installationId = $devices{$serial}{installationId};
              Log3($name,5,$name." - Set selectedDevice: instID: $installationId, serial $serial");
              CommandAttr (undef, "$name vitoconnect_installationID $installationId");
              CommandAttr (undef, "$name vitoconnect_serial $serial");
            }
            $hash->{selectedDevice} = $serial;
            vitoconnect_GetUpdate($hash);                       # neue Abfrage starten
        } else {
            readingsSingleUpdate($hash,'state',"Kein Gateway/Device gefunden, bitte Setup überprüfen",1);  
        }
        return;
    }
    if ($opt eq 'clearMappedErrors' ){
     AnalyzeCommand($hash,"deletereading $name device.messages.errors.mapped.*");
     return;
    }
    
    if ($opt eq 'weekprofile' ){
        my $weekprof_device = $args[0];
        my $weekprof_ref    = $args[1] // return 'Please provide a weekprofile reference!';
        my $mode            = $args[2];
        return "$weekprof_device is no valid weekprofile device!" if !defined $defs{$weekprof_device} || InternalVal($weekprof_device,'TYPE','') ne 'weekprofile';
        return vitoconnect_send_weekprofile($name,$weekprof_device,$weekprof_ref,$mode);
    }

return $val;
}


#####################################################################################################################
# Implementierung set-Befehle neue logik aus raw readings
#####################################################################################################################
sub vitoconnect_Set_New {
    my ($hash, $name, $opt, @args) = @_;
    my $gw = AttrVal( $name, 'vitoconnect_serial', 0 );
    my $val = '';
    
    my $Response = $hash->{".response_$gw"};
    return $val if !defined $Response; # we may add a request for adding that for the next time?
    #if ($Response) {  # Überprüfen, ob $Response Daten enthält
    my $data;
        
    if ( !eval { $data = JSON->new->decode($Response) ; 1 } ) {
        Log3($hash->{NAME}, 1, "JSON decoding error: $@");
        # JSON-Dekodierung fehlgeschlagen, nur Standardoptionen zurückgeben
        return $val;
    }
    return if !defined $data;
    
    my $cmdMapName = {
        setTemperature              =>  'temperature',
        setHysteresis               =>  'value',
        setHysteresisSwitchOnValue  =>  'switchOnValue',
        setHysteresisSwitchOffValue =>  'switchOffValue',
        setMin                      =>  'min',
        setMax                      =>  'max',
        setSchedule                 =>  'entries'
    };
    
    for my $item (@{$data->{data}}) {

        if (exists $item->{commands}) {
            my $feature = $item->{feature};
            Log(5,$name.",vitoconnect_Set_New feature: ". $feature);
            

            for my $commandName (sort keys %{$item->{commands}}) {           #<====== Loop Commands, sort necessary for activate temperature for burners, see below
                my $commandNr = keys %{$item->{commands}};
                my @propertyKeys = keys %{$item->{properties}};
                my $propertyKeysNr = keys %{$item->{properties}};
                my $paramNr = keys %{$item->{commands}{$commandName}{params}};
                
                Log(5,$name.", -vitoconnect_Set_New isExecutable: ". $item->{commands}{$commandName}{isExecutable}); 
                if ($item->{commands}{$commandName}{isExecutable} == 0) {
                    Log(5,$name.", -vitoconnect_Set_New $commandName nicht ausführbar"); 
                    next; #diser Befehl ist nicht ausführbar, nächster 
                }

                Log(5,$name.", -vitoconnect_Set_New feature: ". $feature);
                Log(5,$name.", -vitoconnect_Set_New commandNr: ". $commandNr); 
                Log(5,$name.", -vitoconnect_Set_New commandname: ". $commandName); 
                my $readingNamePrep;
                
                if ( $commandName eq 'setLevels' ) {
                    # duplicate, setMin, setMax can do this https://api.viessmann.com/iot/v2/features/installations/2772216/gateways/7736172146035226/devices/0/features/heating.circuits.0.temperature.levels/commands/setLevels
                    next;
                }
                                        
                if ($commandNr == 1 and $propertyKeysNr == 1) {               # Ein command value = property z.B. heating.circuits.0.operating.modes.active
                    $readingNamePrep .= $feature.".". $propertyKeys[0];
                } elsif ( defined $cmdMapName->{$commandName} ) {
                    $readingNamePrep .= "$feature.$cmdMapName->{$commandName}";
                }

                else {
                    # all other cases, will be defined in param loop
                }
                if( defined $readingNamePrep ) {
                    Log(5,$name.", -vitoconnect_Set_New readingNamePrep: ". $readingNamePrep); 
                }

                if ($paramNr > 2) {                                          #<------- more then 2 parameters, with unsorted JSON can not be handled, but also do not exist at the moment
                    Log(5,$name.", -vitoconnect_Set_New mehr als 2 Parameter in Command $commandName, kann nicht berechnet werden"); 
                    next;
                } elsif ($paramNr == 0){                                     #<------- no parameters, create here, param loop will not be executed
                    $readingNamePrep .= $feature.".".$commandName;
                    $val .= "$readingNamePrep:noArg ";
                    
                    # Set execution
                    if ($opt eq $readingNamePrep) {
                        my $uri = $item->{commands}->{$commandName}->{'uri'};
                        my ($shortUri) = $uri =~ m|.*features/(.*)|; #<=== URI ohne gateway zeug
                        Log(4,$name.", -vitoconnect_Set_New, 0 param, short uri: ".$shortUri);
                        vitoconnect_action($hash,
                            $shortUri,
                            "{}",
                            $name, $opt, @args
                        );
                        return;
                    }
                }
            
            # 1 oder 2 Params, all other cases see above
            my @params = keys %{$item->{commands}{$commandName}{params}};
                foreach my $paramName (@params) {   #<==== Loop params
                   
                   my $otherParam;
                   my $otherReadingName;
                   if ($paramNr == 2) {
                    $otherParam = $params[0] eq $paramName ? $params[1] : $params[0];
                   }
                   
                   my $readingName = $readingNamePrep;
                   if (!defined($readingName)) {                                            #<==== Bisher noch kein Reading gefunden, z.B. setCurve
                     $readingName = $feature.".".$paramName;
                     if (defined($otherParam)) {
                        $otherReadingName = $feature.".".$otherParam;
                     }
                   }
                   
                   my $param = $item->{commands}{$commandName}{params}{$paramName};
                   
                   # fill $val
                   if ($param->{type} eq 'number') {
                        $val .= $readingName.":slider," . ($param->{constraints}{min}) . "," . ($param->{constraints}{stepping}) . "," . ($param->{constraints}{max});
                    # Schauen ob float für slider
                      if ($param->{constraints}{stepping} =~ m/\./)  {
                            $val .= ",1 ";
                      } else { 
                        $val .= " ";
                      }
                   }
                    elsif ($param->{'type'} eq 'string') {
                        if ($commandName eq "setMode") {
                          my $enum = $param->{constraints}->{'enum'};
                          Log(5,$name.", -vitoconnect_Set_New enum: ". $enum); 
                          my $enumNr = scalar @$enum;
                          Log(5,$name.", -vitoconnect_Set_New enumNr: ". $enumNr); 
                        
                          my $i = 1;
                          $val .= $readingName.":";
                           foreach my $value (@$enum) {
                            if ($i < $enumNr) {
                             $val .= $value.",";
                            } else {
                             $val .= $value." ";
                            }
                            $i++;
                           }
                        } else {
                          $val .= $readingName.":textField-long ";
                        }
                        
                    } elsif ($param->{'type'} eq 'Schedule') {
                        $val .= $readingName.":textField-long ";
                    } elsif ($param->{'type'} eq 'boolean') {
                        $val .= "$readingName ";
                    } else {
                        # Ohne type direkter befehl ohne args
                        $val .= "$readingName:noArg ";
                        Log(5,$name.", -vitoconnect_Set_New unknown type: ".$readingName);
                    }
                    
                    Log(5,$name.", -vitoconnect_Set_New exec, opt:".$opt.", readingName:".$readingName);
                    # Set execution
                    if ($opt eq $readingName) {
                        
                        my $data;
                        my $otherData = '';
                        if ($param->{type} eq 'number') {
                            $data = "{\"$paramName\":@args";
                        } 
                        elsif ($param->{type} eq 'Schedule') {
                            my $decoded_args;
                            if ( !eval { $decoded_args = JSON->new->decode($args[0]) ; 1 } ) {;
                                Log3($hash->{NAME}, 2, "JSON decoding error: $@ in vitoconnect set");
                                return "[vitoconnect] set $name $readingName: JSON decoding error $@";
                            }
                             
                            # Transformieren der Datenstruktur
                            my %schedule;
                            for my $day (@$decoded_args) {
                                for my $key (keys %$day) {
                                    push @{$schedule{$key}}, $day->{$key};
                                }
                            }
                             
                            # Konvertieren der transformierten Datenstruktur in JSON
                            my $schedule_data = encode_json(\%schedule);
                            $data = "{\"$paramName\":$schedule_data";
                        }
                        else {
                            $data = "{\"$paramName\":\"@args\"";
                        }
                        Log(5,$name.", -vitoconnect_Set_New, paramName:".$paramName.", args:".Dumper(\@args));
                        
                        # 2 params, one can be set the other must just be read and handed overload
                        # This logic ensures that we get the correct names in an unsortet JSON
                        if (defined($otherReadingName)) {
                           my $otherValue = ReadingsVal($name,$otherReadingName,"");
                          if ($param->{type} eq 'number') {
                           $otherData = ",\"$otherParam\":$otherValue";
                          } else {
                           $otherData = ",\"$otherParam\":\"$otherValue\"";
                          }
                        }
                        $data .= $otherData . '}';
                        my $uri = $item->{commands}->{$commandName}->{'uri'};
                        my ($shortUri) = $uri =~ m|.*features/(.*)|; #<=== URI ohne gateway zeug
                        Log(4,$name.", -vitoconnect_Set_New, short uri:".$shortUri.", data:".$data);
                        vitoconnect_action($hash,
                            $shortUri,
                            $data,
                            $name, $opt, @args
                        );
                        return;
                    }
                }
            }
        }
    }
    
    # Rückgabe der dynamisch erstellten $val Variable
    Log(5,"$name, -vitoconnect_Set_New val ended with: $val");
    #Log(5,$name.", -vitoconnect_Set_New ended ");
    
    return $val;
}

sub vitoconnect_Notify {
    my $hash     = shift // return;
    my $dev_hash = shift // return;
    
    my $filename = AttrVal($hash->{NAME},'confFile',undef) // return; # nothing to read...
    
    my $ownName = $hash->{NAME} // return; # own name / hash

    return if IsDisabled($ownName); # Return without any further action if the module is disabled

    my $devName = $dev_hash->{NAME} // return; # Device that created the events
    return if $devName ne 'global';

    my $events = deviceEvents($dev_hash,1);
    return if !$events;

    for my $event ( @{$events} ) {
        next if !defined $event;
        next if $event !~ m{FILEWRITE}xms;
        return vitoconnect_readConfFile($hash, $filename) if $filename =~ m{$event}xms;        
    }
    return;
}


#####################################################################################################################
# Attribute setzen/ändern/löschen
#####################################################################################################################
sub vitoconnect_Attr {
    my ($cmd,$name,$attr_name,$attr_value ) = @_;
    
    Log(5,$name.", ".$cmd ." vitoconnect_: ".($attr_name // 'undef')." value: ".($attr_value // 'undef'));
    if ($cmd eq 'set')  {
        if ($attr_name eq "vitoconnect_raw_readings" )      {
            if ($attr_value !~ /^0|1|svn$/)                     {
                my $err = "Invalid argument $attr_value to $attr_name. Must be 0, 1 or svn.";
                Log3($name,1,"$name, vitoconnect_Attr: $err");
                return $err;
            }
            Log3($name,1,"$name - using svn mappings might not be supported in the future!")                      # Warnung ins Log 
                if !$init_done && $attr_value eq 'svn';
            return;
        }
        if ( $attr_name eq 'vitoconnect_disable_raw_readings' || $attr_name eq 'vitoconnect_gw_readings' || $attr_name eq 'vitoconnect_actions_active' )  {
            if ($attr_value !~ /^0|1$/)                     {
                my $err = "Invalid argument $attr_value to $attr_name. Must be 0 or 1.";
                Log3($name,1,"$name, vitoconnect_Attr: $err");
                return $err;
            }
            return;
        }
        if ($attr_name eq 'vitoconnect_mappings') {
            my $RequestListMapping = eval { $attr_value };
            if ($@) {
                # Fehlerbehandlung
                my $err = "Invalid argument: $@";
                return $err;
            }
            my $hash = $defs{$name};
            delete $hash->{helper}->{mappings};
            for ( keys %{$RequestListMapping} ) {
                next if ref $RequestListMapping->{$_} ne 'SCALAR';
                $hash->{helper}->{mappings}->{$_} = $RequestListMapping->{$_};
            }
            my $confFile = AttrVal($name,'confFile',undef) // return;
            vitoconnect_readConfFile($hash, $confFile);
            return;
        }
        
        elsif ($attr_name eq 'vitoconnect_serial')                      {
            if (length($attr_value) != 16)                      {
                my $err = "Invalid argument $attr_value to $attr_name. Must be 16 characters long.";
                Log3($name,1,"$name, vitoconnect_Attr: $err");
                return $err;
            }
        }
        elsif ($attr_name eq 'vitoconnect_installationID')                      {
            if (length($attr_value) < 2)                      {
                my $err = "Invalid argument $attr_value to $attr_name. Must be at least 2 characters long.";
                Log3($name,1,"$name, vitoconnect_Attr: $err");
                return $err;
            }
        }
        elsif ($attr_name eq 'disable')                     {
        }
        elsif ($attr_name eq 'verbose')                     {
        }
        elsif ( $attr_name eq 'confFile' ) {
            my $hash = $defs{$name};
            delete $hash->{CONFIGFILE};
            undef $hash->{helper}->{mappings};          
            my ($err, $mapping) = vitoconnect_readConfFile($hash, $attr_value);
            return $err if $err;
            $hash->{CONFIGFILE} = $attr_value;
            return;
        }

        else                                                {
            # return "Unknown attr $attr_name";
            # This will return all attr, e.g. room. We do not want to see messages here.
            # Log(1,$name.", ".$cmd ." Unknow attr vitoconnect_: ".($attr_name // 'undef')." value: ".($attr_value // 'undef'));
        }
    }
    elsif ($cmd eq 'del') {
        my $hash = $defs{$name};
        if ($attr_name eq 'confFile') {
            #undef $RequestListMapping;
            delete $hash->{CONFIGFILE};
            delete $attr{$name}{confFile};
            delete $hash->{helper}->{mappings};
            delete $hash->{'.sets'};
            my $RequestListMapping = AttrVal($name,'vitoconnect_mappings',undef) // return;
            my $RequestListMapping = eval { $RequestListMapping };
            return if $@ || ref $RequestListMapping ne 'HASH';
            
            for ( keys %{$RequestListMapping} ) {
                next if ref $RequestListMapping->{$_} ne 'SCALAR';
                $hash->{helper}->{mappings}->{$_} = $RequestListMapping->{$_};
            }
            return;
        }
        if ($attr_name eq 'vitoconnect_mappings') {
            delete $hash->{helper}->{mappings};
            delete $hash->{'.sets'};
            my $confFile = AttrVal($name,'confFile',undef) // return;
            vitoconnect_readConfFile($hash, $confFile);
            return;
        }
    }
    return;
}


#####################################################################################################################
# # Abfrage aller Werte starten
#####################################################################################################################
sub vitoconnect_GetUpdate {
    my $hash = shift // return;
    my $name = $hash->{NAME} // return;
    RemoveInternalTimer($hash);
    Log3($name,4,$name." - GetUpdate called ...");
    if (IsDisabled($name))      {   # Device disabled
        Log3($name,4,$name." - device disabled");
        InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);   # nach Intervall erneut versuchen
        return;
    }
    else                        {   # Device nicht disabled
        vitoconnect_getResource($hash);
    }
    return;
}


#####################################################################################################################
# Werte für: Access-Token, Install-ID, Gateway anfragen
#####################################################################################################################
sub vitoconnect_getCode {
    my $hash   = shift // return;  
    my $name   = $hash->{NAME} // return;
    RemoveInternalTimer($hash);
    my $isiwebpasswd = vitoconnect_ReadKeyValue($name,'passwd');        # verschlüsseltes Kennwort auslesen
    my $client_id    = $hash->{apiKey};
    if (!defined($client_id))   {   # $client_id/apiKey nicht definiert
        Log3($name,1,"$name - set apiKey first");                       # Fehlermeldung ins Log
        readingsSingleUpdate($hash,'state','Set apiKey to continue',1); # Reading 'state' setzen
        return;
    }

    my $param = {
        url => $vitoconnect_authorizeURL
        ."?client_id=".$client_id
        ."&redirect_uri=${vitoconnect_callback_uri}&"
        ."code_challenge=${vitoconnect_client_secret}&"
        ."&scope=IoT%20User%20offline_access"
        ."&response_type=code",
        hash            => $hash,
        header          => "Content-Type: application/x-www-form-urlencoded",
        ignoreredirects => 1,
        user            => $hash->{user},
        pwd             => $isiwebpasswd,
        sslargs         => { SSL_verify_mode => 0 },
        timeout         => $hash->{timeout},
        method          => "POST",
        callback        => \&vitoconnect_getCodeCallback
    };

    #Log3 $name, 4, "$name - user=$param->{user} passwd=$param->{pwd}";
    #Log3 $name, 5, Dumper($hash);
    HttpUtils_NonblockingGet($param);   # Anwort an: vitoconnect_getCodeCallback()
    return;
}


#####################################################################################################################
# Rückgabe: Access-Token, Install-ID, Gateway von vitoconnect_getCode Anfrage
#####################################################################################################################
sub vitoconnect_getCodeCallback {
    my ($param,$err,$response_body ) = @_;  # Übergabe-Parameter
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err eq "")                 {   # Antwort kein Fehler
        Log3($name,4,$name." - getCodeCallback went ok");
        Log3($name,5,$name." - Received response: ".$response_body);
        $response_body =~ /code=(.*)"/;
        $hash->{".code"} = $1;          # in Internal '.code' speichern
        Log3($name,4,$name." - code: ".$hash->{".code"});
        if ( $hash->{".code"} && $hash->{".code"} ne "4" )  {
            $hash->{login} = "ok";      # Internal 'login'
        }
        else {
            $hash->{login} = "failure"; # Internal 'login'
        }
    }
    else                            {   # Fehler als Antwort
        Log3($name,1,$name.", vitoconnect_getCodeCallback - An error occured: ".$err);
        $hash->{login} = "failure";
    }

    if ( $hash->{login} eq "ok" )   {   # Login hat geklappt
        readingsSingleUpdate($hash,"state","login ok",1);       # Reading 'state' setzen
        vitoconnect_getAccessToken($hash);  # Access & Refresh-Token holen
    }
    else                            {   # Fehler beim Login
        readingsSingleUpdate($hash,"state","Login failure. Check password and apiKey",1);   # Reading 'state' setzen
        Log3($name,1,$name." - Login failure. Check password and apiKey");
        InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);   # Forum: #880
        return;
    }
    return;
}


#####################################################################################################################
# Access & Refresh-Token holen
#####################################################################################################################
sub vitoconnect_getAccessToken {
    my ($hash)    = @_;                 # Übergabe-Parameter
    my $name      = $hash->{NAME};      # Device-Name
    my $client_id = $hash->{apiKey};    # Internal: apiKey
    my $param     = {
        url    => $vitoconnect_tokenURL,
        hash   => $hash,
        header => "Content-Type: application/x-www-form-urlencoded",
        data   => "grant_type=authorization_code"
        . "&code_verifier="
        . $vitoconnect_client_secret
        . "&client_id=$client_id"
        . "&redirect_uri=$vitoconnect_callback_uri"
        . "&code="
        . $hash->{".code"},
        sslargs  => { SSL_verify_mode => 0 },
        method   => "POST",
        timeout  => $hash->{timeout},
        callback => \&vitoconnect_getAccessTokenCallback
    };

    #Log3 $name, 1, "$name - " . $param->{"data"};
    HttpUtils_NonblockingGet($param);   # Anwort an: vitoconnect_getAccessTokenCallback()
    return;
}


#####################################################################################################################
# Access & Refresh-Token speichern, Antwort auf: vitoconnect_getAccessToken
#####################################################################################################################
sub vitoconnect_getAccessTokenCallback {
    my ($param,$err,$response_body) = @_;   # Übergabe-Parameter
    my $hash = $param->{hash};
    my $name = $hash->{NAME};   # Device-Name

    if ($err eq "")                 {   # kein Fehler bei Antwort
        Log3($name,4,$name." - getAccessTokenCallback went ok");
        Log3($name,5,$name." - Received response: ".$response_body."\n");
        
        my $decoded_json;
        if ( !eval { $decoded_json = JSON->new->decode($response_body) ; 1 } ) {
            Log3($hash->{NAME}, 1, "JSON decoding error: $@");
            Log3($name,1,"$name, vitoconnect_getAccessTokenCallback: JSON error while request: $@");
            InternalTimer(gettimeofday() + $hash->{interval},'vitoconnect_GetUpdate',$hash);
            return;
        }
        return if !defined $decoded_json;
               
        my $access_token = $decoded_json->{access_token};               # aus JSON dekodieren
        if ($access_token ne "")    {
            $hash->{'.access_token'} = $access_token;                  # in Internals speichern
            $hash->{refresh_token} = $decoded_json->{refresh_token};    # in Internals speichern

            Log3($name,4,$name." - Access Token: ".substr($access_token,0,20)."...");
            vitoconnect_getGw($hash);   # Abfrage Gateway-Serial
        }
        else                        {
            Log3($name,1,$name." - Access Token: nicht definiert");
            Log3($name,5,$name." - Received response: ".$response_body."\n");
            InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
            return;
        }
    }
    else                            {   # Fehler bei Antwort
        Log3($name,1,$name.",vitoconnect_getAccessTokenCallback - getAccessToken: An error occured: ".$err);
        InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
        return;
    }
    return;
}


#####################################################################################################################
# neuen Access-Token anfragen
#####################################################################################################################
sub vitoconnect_getRefresh {
    my $hash      = shift // return;
    my $caller    = shift // 'update';
    my $name      = $hash->{NAME} // return;
    my $client_id = $hash->{apiKey};
    my $param     = {
        url    => $vitoconnect_tokenURL,
        hash   => $hash,
        header => "Content-Type: application/x-www-form-urlencoded",
        data   => "grant_type=refresh_token"
          . "&client_id=$client_id"
          . "&refresh_token="
          . $hash->{"refresh_token"},
        sslargs  => { SSL_verify_mode => 0 },
        method   => "POST",
        timeout  => $hash->{timeout},
        caller  => $caller,  # <–– Kontext hier speichern!
        callback => \&vitoconnect_getRefreshCallback
    };

    #Log3 $name, 1, "$name - " . $param->{"data"};
    HttpUtils_NonblockingGet($param);
    return;
}


#####################################################################################################################
# neuen Access-Token speichern
#####################################################################################################################
sub vitoconnect_getRefreshCallback {
    my ($param,$err,$response_body) = @_;   # Übergabe-Parameter
    my $hash = $param->{hash};
    my $name = $hash->{NAME} // return;
    my $caller = $param->{caller} // 'update';  # Default: update

    if ($err eq "")                 {
        Log3($name,4,$name.". - getRefreshCallback went ok");
        Log3($name,5,$name." - Received response: ".$response_body."\n");
        
        my $decoded_json;
        if ( !eval { $decoded_json = JSON->new->decode($response_body) ; 1 } ) {
            Log3($hash->{NAME}, 1, "JSON decoding error: $@");
            Log3($name,1,"$name, vitoconnect_getRefreshCallback: JSON error while request: $@");
            InternalTimer(gettimeofday() + $hash->{interval},'vitoconnect_GetUpdate',$hash) if $caller ne 'action';
            return;
        }
        return if !defined $decoded_json;
               
        my $access_token = $decoded_json->{access_token};               # aus JSON dekodieren
        if ($access_token ne '')    {
            $hash->{'.access_token'} = $access_token;                  # in Internals speichern
            Log3($name,4,$name." - Access Token: ".substr($access_token,0,20)."...");
            #vitoconnect_getGw($hash);  # Abfrage Gateway-Serial
            # directly call get resource to save API calls
            return vitoconnect_getResource($hash) if $caller ne 'action';
            return vitoconnect_action(
                    $hash,
                    $hash->{'.retry_feature'},
                    $hash->{'.retry_data'},
                    $name,
                    $hash->{'.retry_opt'},
                    @{ $hash->{'.retry_args'} }
                );
        }
        else {
            Log3 $name, 1, "$name - Access Token: nicht definiert";
            Log3 $name, 5, "$name - Received response: $response_body\n";
            InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash) if $caller ne 'action';    # zurück zu getCode?
            return;
        }
    }
    else {
        Log3 $name, 1, "$name - getRefresh: An error occured: $err";
        InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
        return;
    }
    return;
}


#####################################################################################################################
# Abfrage Gateway-Serial
#   https://documentation.viessmann.com/static/iot/overview
#####################################################################################################################
sub vitoconnect_getGw {
    my $hash         = shift // return;  # Übergabe-Parameter
    my $name         = $hash->{NAME};
    my $access_token = $hash->{'.access_token'};
    my $param        = {
        url      => "${vitoconnect_iotURL_V1}gateways",
        hash     => $hash,
        header   => "Authorization: Bearer $access_token",
        timeout  => $hash->{timeout},
        sslargs  => { SSL_verify_mode => 0 },
        callback => \&vitoconnect_getGwCallback
    };
    HttpUtils_NonblockingGet($param);
    return;
}


#####################################################################################################################
# Gateway-Serial speichern, Anwort von Abfrage Gateway-Serial
#####################################################################################################################
sub vitoconnect_getGwCallback {
    my ($param,$err,$response_body) = @_;   # Übergabe-Parameter
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err eq '')                         {   # kein Fehler aufgetreten
        Log3($name,4,$name." - getGwCallback went ok");
        Log3($name,5,$name." - Received response: ".$response_body."\n");
        #my $items = eval {decode_json($response_body)};
        my $items;
        if ( !eval { $items = JSON->new->decode($response_body) ; 1 } ) {
            readingsSingleUpdate($hash,'state',"JSON error while request: $@",1);  # Reading 'state'
            Log3($name,1,"$name, vitoconnect_getGwCallback: JSON error while request: $@");
            InternalTimer(gettimeofday() + $hash->{interval},'vitoconnect_GetUpdate',$hash);
            return;
        }
        $err = vitoconnect_errorHandling($hash,$items);
        if ($err ==1){
           return;
        }
        
        if ($hash->{".logResponseOnce"} )   {
            my $dir         = path( AttrVal("global","logdir","log"));
            my $file        = $dir->child("gw.json");
            my $file_handle = $file->openw_utf8();
            $file_handle->print(Dumper($items));            # Datei 'gw.json' schreiben
            $file_handle->close();
            Log3($name,3,$name." Datei: ".$dir."/".$file." geschrieben");
            }
            
            # Alle Gateways holen und in hash schreiben, immer machen falls neue Geräte hinzu kommen
            my %devices;
            
            # Über jedes Gateway-Element in der JSON-Datenstruktur iterieren
            foreach my $gateway (@{$items->{data}}) {
              if (defined $gateway->{serial} && defined $gateway->{installationId}) {
                $devices{$gateway->{serial}} = {
                     installationId => $gateway->{installationId},
                     gatewayType    => $gateway->{gatewayType},
                     version        => $gateway->{version}
                   };
              }
            }

            $hash->{devices} = { %devices };
            
            if ( defined(AttrVal( $name, 'vitoconnect_installationID', 0 )) 
                      && AttrVal( $name, 'vitoconnect_installationID', 0 ) ne "" 
                      && AttrVal( $name, 'vitoconnect_installationID', 0 ) != 0 
              && defined(AttrVal( $name, 'vitoconnect_serial', 0 )) 
                      && AttrVal( $name, 'vitoconnect_serial', 0 ) ne "" 
                      && AttrVal( $name, 'vitoconnect_serial', 0 ) != 0 )  {
              # Attribute sind gesetzt, nichts zu tun
              Log3($name,5,$name." - getGW all atributes set already attr: instID: ".AttrVal( $name, 'vitoconnect_installationID', 0 ).
                                                                        ", serial: ".AttrVal( $name, 'vitoconnect_serial', 0 ));
              } else 
              {
              # Prüfungen der Gateways und weiteres vorgehen 
              my $num_devices = scalar keys %devices;
            
              if ($num_devices == 0) {
                readingsSingleUpdate($hash,"state","Keine Gateways/Devices gefunden, Account prüfen",1);
                return;
              } elsif ($num_devices == 1) {
                readingsSingleUpdate($hash,"state","Genau ein Gateway/Device gefunden",1);
               
               my ($serial) = keys %devices;
               my $installationId = $devices{$serial}->{installationId};
               Log3($name,4,$name." - getGW exactly one Device found set attr: instID: $installationId, serial $serial");
               my $result;
               $result = CommandAttr (undef, "$name vitoconnect_installationID $installationId");
               if ($result) {
                Log3($name, 1, "Error setting vitoconnect_installationID: $result");
                return;
               }
               $result = CommandAttr (undef, "$name vitoconnect_serial $serial");
               if ($result) {
                Log3($name, 1, "Error setting vitoconnect_serial: $result");
                return;
               }
               Log3($name, 4, "Successfully set vitoconnect_serial and vitoconnect_installationID attributes for $name");
              } else {
                readingsSingleUpdate($hash,"state","Mehrere Gateways/Devices gefunden, bitte eines auswählen über selectDevice",1);
                return;
              }
            }
            
      if (AttrVal( $name, 'vitoconnect_gw_readings', 0 ) eq "1") {
        readingsSingleUpdate($hash,"gw",$response_body,1);  # im Reading 'gw' merken
        readingsSingleUpdate($hash,"number_of_gateways",scalar keys %devices,1);
      }

        # Alle Infos besorgt, rest nur für logResponceOnce
        if ($hash->{".logResponseOnce"} )   {
          vitoconnect_getInstallation($hash);
          vitoconnect_getInstallationFeatures($hash);
        } else {
          vitoconnect_getResource($hash);
        }
    }
    else                                    {   # Fehler aufgetreten
        Log3($name,1,$name." - An error occured: ".$err);
        InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
    }
    return;
}


#####################################################################################################################
# Abfrage Install-ID
#   https://documentation.viessmann.com/static/iot/overview
#####################################################################################################################
sub vitoconnect_getInstallation {
    my ($hash)       = @_;
    my $name         = $hash->{NAME};
    my $access_token = $hash->{".access_token"};
    my $param        = {
        url      => "${vitoconnect_iotURL_V1}installations",
        hash     => $hash,
        header   => "Authorization: Bearer $access_token",
        timeout  => $hash->{timeout},
        sslargs  => { SSL_verify_mode => 0 },
        callback => \&vitoconnect_getInstallationCallback
        };
    HttpUtils_NonblockingGet($param);
    return;
}


#####################################################################################################################
# Install-ID speichern, Antwort von Abfrage Install-ID
#####################################################################################################################
sub vitoconnect_getInstallationCallback {
    my ( $param, $err, $response_body ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $gw           = AttrVal( $name, 'vitoconnect_serial', 0 );

    if ($err eq "")                         {
        Log3 $name, 4, "$name - getInstallationCallback went ok";
        Log3 $name, 5, "$name - Received response: $response_body";
        my $items; # = eval { decode_json($response_body) };
        if ( !eval { $items = JSON->new->decode($response_body) ; 1 } ) {
            readingsSingleUpdate( $hash, "state","JSON error while request: ".$@,1);
            Log3($name,1,$name.", vitoconnect_getInstallationCallback: JSON error while request: ".$@);
            InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
            return;
        }
        if ($hash->{".logResponseOnce"})    {
            my $dir         = path( AttrVal("global","logdir","log"));
            my $file        = $dir->child("installation_" . $gw . ".json");
            my $file_handle = $file->openw_utf8();
            $file_handle->print(Dumper($items));                # Datei 'installation.json' schreiben
            $file_handle->close();
            Log3($name,3,$name." Datei: ".$dir."/".$file." geschrieben");
        }
            
        if (AttrVal( $name, 'vitoconnect_gw_readings', 0 ) eq "1") {
           readingsSingleUpdate( $hash, "installation", $response_body, 1 );
        }
        
        vitoconnect_getDevice($hash);

    }
    else {
        Log3 $name, 1, "$name - An error occured: $err";
        InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
    }
    return;
}


#####################################################################################################################
# Abfrage von Install-features speichern
#####################################################################################################################
sub vitoconnect_getInstallationFeatures {
    my $hash         = shift // return;
    my $name         = $hash->{NAME} // return;
    my $access_token = $hash->{'.access_token'};
    my $installation = AttrVal( $name, 'vitoconnect_installationID', 0 );
    
    
    # installation features      #Fixme call only once
    my $param = {
        url     => "${vitoconnect_iotURL_V2}installations/${installation}/features",
        hash    => $hash,
        header  => "Authorization: Bearer $access_token",
        timeout => $hash->{timeout},
        sslargs => { SSL_verify_mode => 0 },
        callback => \&vitoconnect_getInstallationFeaturesCallback
    };
    
    HttpUtils_NonblockingGet($param);
    return;
}


#####################################################################################################################
#Install-features speichern
#####################################################################################################################
sub vitoconnect_getInstallationFeaturesCallback {
    my ( $param, $err, $response_body ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME} // return;
    my $gw   = AttrVal( $name, 'vitoconnect_serial', 0 );
    
    #my $decode_json = eval {decode_json($response_body)};
    my $decoded_json;
    if ( !eval { $decoded_json = JSON->new->decode($response_body) ; 1 } ) {
        Log3($name,1,"$name, getInstallationFeaturesCallback: JSON error while request: $@");
        return;
    }

    if ((defined($err) && $err ne '') || (defined($decoded_json->{statusCode}) && $decoded_json->{statusCode} ne "")) {   # Fehler aufgetreten
        Log3($name,1,$name.",vitoconnect_getFeatures: Fehler während installation features: ".$err." :: ".$response_body);
        $err = vitoconnect_errorHandling($hash,$decoded_json);
        if ($err ==1){
           return;
        }
    }
    else                                                {   #  kein Fehler aufgetreten
    
         if ($hash->{".logResponseOnce"})    {
            my $dir         = path( AttrVal("global","logdir","log"));
            my $file        = $dir->child("installation_features_" . $gw . ".json");
            my $file_handle = $file->openw_utf8();
            $file_handle->print(Dumper($decoded_json));                # Datei 'installation.json' schreiben
            $file_handle->close();
            Log3($name,3,$name." Datei: ".$dir."/".$file." geschrieben");
        }
        
        if (AttrVal( $name, 'vitoconnect_gw_readings', 0 ) eq "1") {
            readingsSingleUpdate($hash,"installation_features",$response_body,1);   # im Reading 'installation_features' merken
        }

    return;
    }
}


#####################################################################################################################
# Abfrage Device-ID
#####################################################################################################################
sub vitoconnect_getDevice {
    my ($hash)       = @_;
    my $name         = $hash->{NAME};
    my $access_token = $hash->{".access_token"};
    my $installation = AttrVal( $name, 'vitoconnect_installationID', 0 );
    my $gw           = AttrVal( $name, 'vitoconnect_serial', 0 );
    
    Log(5,"$name, --getDevice gw for call set: $gw");

    my $param        = {
        url     => "${vitoconnect_iotURL_V1}installations/${installation}/gateways/${gw}/devices",
        hash    => $hash,
        header  => "Authorization: Bearer $access_token",
        timeout => $hash->{timeout},
        sslargs => { SSL_verify_mode => 0 },
        callback => \&vitoconnect_getDeviceCallback
    };
    HttpUtils_NonblockingGet($param);

    return;
}


#####################################################################################################################
# Device-ID speichern, Anwort von Abfrage Device-ID
#####################################################################################################################
sub vitoconnect_getDeviceCallback {
    my ( $param, $err, $response_body ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $gw   = AttrVal( $name, 'vitoconnect_serial', 0 );

   Log(5,$name.", -getDeviceCallback get device gw: ".$gw);
    if ($err eq "")                         {
        Log3 $name, 4, "$name - getDeviceCallback went ok";
        Log3 $name, 5, "$name - Received response: $response_body\n";
        #my $items = eval { decode_json($response_body) };
        
        my $items;
        if ( !eval { $items = JSON->new->decode($response_body) ; 1 } ) {
            RemoveInternalTimer($hash);
            readingsSingleUpdate($hash,"state","JSON error while request: ".$@,1);
            Log3($name,1,$name.", vitoconnect_getDeviceCallback: JSON error while request: ".$@);           
            InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
            return;
        }
        if ( $hash->{".logResponseOnce"} )  {
            my $dir         = path( AttrVal("global","logdir","log"));
            my $filename    = "device_" . $gw . ".json";
            my $file        = $dir->child($filename);
            my $file_handle = $file->openw_utf8();
            $file_handle->print(Dumper($items));            # Datei 'device.json' schreiben
            $file_handle->close();
            Log3($name,3,$name." Datei: ".$dir."/".$file." geschrieben");
        }
        if (AttrVal( $name, 'vitoconnect_gw_readings', 0 ) eq "1") {
          readingsSingleUpdate($hash,"device",$response_body,1);    # im Reading 'device' merken
        }
        vitoconnect_getFeatures($hash);
    }
    else {
        if ((defined($err) && $err ne "")) {    # Fehler aufgetreten
        Log3($name,1,$name." - An error occured: ".$err);
        } else {
        Log3($name,1,$name." - An undefined error occured");
        }
        RemoveInternalTimer($hash);
        InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
    }
    return;
}


#####################################################################################################################
# Abruf GW Features, Anwort von Abfrage Device-ID
#   https://documentation.viessmann.com/static/iot/overview
#####################################################################################################################
sub vitoconnect_getFeatures {
    my ($hash)       =  shift;  # Übergabe-Parameter
    my $name         = $hash->{NAME};
    my $access_token = $hash->{".access_token"};
    my $installation = AttrVal( $name, 'vitoconnect_installationID', 0 );
    my $gw           = AttrVal( $name, 'vitoconnect_serial', 0 );
    my $dev          = AttrVal($name,'vitoconnect_device',0);   # Attribut: vitoconnect_device (0,1), Standard: 0

    Log3($name,4,$name." - getFeatures went ok");

# Gateway features
    my $param = {
        url    => $vitoconnect_iotURL_V2
        ."installations/".$installation."/gateways/".$gw."/features",
        hash   => $hash,
        header => "Authorization: Bearer ".$access_token,
        timeout => $hash->{timeout},
        sslargs => { SSL_verify_mode => 0 },
        callback => \&vitoconnect_getFeaturesCallback
    };
    
    HttpUtils_NonblockingGet($param);
    return;
}


#####################################################################################################################
# GW Features speichern
#   https://documentation.viessmann.com/static/iot/overview
#####################################################################################################################
sub vitoconnect_getFeaturesCallback {
    my ( $param, $err, $response_body ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $gw           = AttrVal( $name, 'vitoconnect_serial', 0 );
    
    #my $decode_json = eval {decode_json($response_body)};
    my $decoded_json;
    if ( !eval { $decoded_json = JSON->new->decode($response_body) ; 1 } ) {
        Log3($name,1,"$name, getFeaturesCallback: JSON error while request: $@");
        return;
    }

    if ((defined($err) && $err ne '') || (defined($decoded_json->{statusCode}) && $decoded_json->{statusCode} ne "")) {   # Fehler aufgetreten
        Log3($name,1,$name.",vitoconnect_getFeatures: Fehler während Gateway features: ".$err." :: ".$response_body);
        $err = vitoconnect_errorHandling($hash,$decoded_json);
        if ($err ==1){
           return;
        }
    }   
    else                                                {   # kein Fehler aufgetreten
    
      if ($hash->{".logResponseOnce"})    {
            my $dir         = path( AttrVal("global","logdir","log"));
            my $file        = $dir->child("gw_features_" . $gw . ".json");
            my $file_handle = $file->openw_utf8();
            $file_handle->print(Dumper($decoded_json));                # Datei 'installation.json' schreiben
            $file_handle->close();
            Log3($name,3,$name." Datei: ".$dir."/".$file." geschrieben");
      }
    
    if (AttrVal( $name, 'vitoconnect_gw_readings', 0 ) eq "1") {    
        readingsSingleUpdate($hash,"gw_features",$response_body,1);  # im Reading 'gw_features' merken
    }
        vitoconnect_getResource($hash);
    }
}


#####################################################################################################################
# Get der Daten vom Gateway
# Hier für den normalen Update
# Es wird im Sub entschieden ob für alle Gateways oder für eine vorgegeben Gateway Serial
#####################################################################################################################
sub vitoconnect_getResource {
    my ($hash)       = shift;               # Übergabe-Parameter
    my $name         = $hash->{NAME};   # Device-Name
    my $access_token = $hash->{".access_token"};
    my $installation = AttrVal( $name, 'vitoconnect_installationID', 0 );
    my $gw           = AttrVal( $name, 'vitoconnect_serial', 0 );
    my $dev          = AttrVal($name,'vitoconnect_device',0);

    Log3($name,4,$name." - enter getResourceOnce");
    Log3($name,4,$name." - access_token: ".substr($access_token,0,20)."...");
    Log3($name,4,$name." - installation: ".$installation);
    Log3($name,4,$name." - gw: ".$gw);
    if ($access_token eq "" || $installation eq "" || $gw eq "") {  # noch kein: Token, ID, GW
        vitoconnect_getCode($hash);
        return;
    }
    my $param = {
        url => $vitoconnect_iotURL_V2
        ."installations/".$installation."/gateways/".$gw."/devices/".$dev."/features",
        hash     => $hash,
        gw       => $gw,
        header   => "Authorization: Bearer $access_token",
        timeout  => $hash->{timeout},
        sslargs  => { SSL_verify_mode => 0 },
        callback => \&vitoconnect_getResourceCallback
    };
    HttpUtils_NonblockingGet($param);   # non-blocking aufrufen --> Antwort an: vitoconnect_getResourceCallback
    return;
}


#####################################################################################################################
# Verarbeiten der Daten vom Gateway und schreiben in Readings
# Entweder statisch gemapped oder über attribute mapping gemapped oder nur raw Werte
# Wenn gemapped wird wird für alle Treffer des Mappings kein raw Wert mehr aktualisiert
#####################################################################################################################
sub vitoconnect_getResourceCallback {   
    my ($param,$err,$response_body) = @_;   # Übergabe-Parameter
    my $hash   = $param->{hash};
    my $name   = $hash->{NAME};
    my $gw     = AttrVal( $name, 'vitoconnect_serial', 0 );
    my @days = qw(mon tue wed thu fri sat sun); # Reihenfolge der Wochentage festlegen für type Schedule
    
    Log(5,$name.", -getResourceCallback started");
    Log3($name,5,$name." getResourceCallback calles with gw:".$gw); 
    
    my $allreadings; #store all updated readings for clients as well...

    if ($err eq "")                         {   # kein Fehler aufgetreten
        Log3($name,4,$name." - getResourceCallback went ok");
        Log3($name,5,$name." - Received response: ".substr($response_body,0,100)."...");
        my $items;
        if ( !eval { $items = JSON->new->decode($response_body) ; 1 } ) {
            readingsSingleUpdate($hash,"state","JSON error while request: ".$@,1);  # Reading 'state'
            Log3($name,1,$name.", vitoconnect_getResourceCallback: JSON error while request: ".$@);
            InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
            return;
        }
        return if !defined $items; # needs timer as well?
        
        $err = vitoconnect_errorHandling($hash,$items);
        if ($err ==1){
           return;
        }

        if ($hash->{".logResponseOnce"} ) {
            my $dir         = path(AttrVal("global","logdir","log"));   # Verzeichnis
            my $file        = $dir->child("resource_".$gw.".json");             # Dateiname
            my $file_handle = $file->openw_utf8();
            $file_handle->print(Dumper($response_body));                        # Datei 'resource.json' schreiben
            $file_handle->close();
            Log3($name,3,$name." Datei: ".$dir."/".$file." geschrieben");
            $hash->{".logResponseOnce"} = 0;
        }
        
        $hash->{".response_$gw"} = $response_body;
        
        #Log(5,$name.", translations count:".scalar keys %translations);
        #Log(5,"$name, RequestListMapping count:".scalar keys %{$hash->{helper}->{mappings}};   #$RequestListMapping);
        
        readingsBeginUpdate($hash);
        for my $feature ( @{ $items->{data} } ) {
            my $properties = $feature->{properties};
            if (AttrVal( $name, 'vitoconnect_actions_active', 0 ) eq "1") { # Write all commands
                if (exists $feature->{commands}) {
                    for my $command (keys %{$feature->{commands}}) {
                        my $Reading = $feature->{feature}.".".$command;
                        my $Value = $feature->{commands}{$command}{uri};
                        readingsBulkUpdate($hash,$Reading,$Value,1);
                        $allreadings->{$Reading} = $Value;
                    }
                }
            }
        
            
            for my $key ( sort keys %$properties ) {
                
                my $Reading;
                
                if ( defined $hash->{helper} && scalar keys %{$hash->{helper}->{mappings}} > 0) {
                # Use RequestListMapping from Attr
                $Reading =
                    $hash->{helper}->{mappings}->{ "$feature->{feature}.$key" };
                }

                if ( !defined($Reading) && AttrVal( $name, 'vitoconnect_disable_raw_readings', 0 ) eq "1" )
                {   
                    next;
                }

                if ( !defined $Reading && AttrVal( $name, 'vitoconnect_raw_readings', 1 ) !~ m{0|svn}x )
                {   
                    $Reading = $feature->{feature} . ".$key";
                }
                
                my $Type  = $properties->{$key}->{type};
                my $Value = $properties->{$key}->{value};
                $Value =~ s/\x{FFFD}+/[VUC]/g; # Ersetze aufeinanderfolgende Vorkommen von U+FFFD durch "unknown characters" siehe https://forum.fhem.de/index.php?msg=1334504
                #$Value =~ s/[^[:print:]]+//g; # Behalte alle druckbaren Zeichen 
                my $comma_separated_string = "";
                if ( $Type eq "array" ) {
                    if ( defined($Value) ) {
                        if (ref($Value->[0]) eq 'HASH') {
                        foreach my $entry (@$Value) {
                            foreach my $hash_key (sort keys %$entry) {
                                if ($hash_key ne "audiences") {
                                    my $hash_value = $entry->{$hash_key};
                                    if (ref($hash_value) eq 'ARRAY') {
                                        $comma_separated_string .= join(", ", @$hash_value) . ", ";
                                    } else {
                                        $comma_separated_string .= $hash_value . ", ";
                                    }
                                }
                            }
                        }
                         # Entferne das letzte Komma und Leerzeichen
                         $comma_separated_string =~ s/, $//;
                         readingsBulkUpdate($hash,$Reading,$comma_separated_string);
                         $allreadings->{$Reading} = $comma_separated_string;
                        }
                        elsif (ref($Value) eq 'ARRAY') {
                            $comma_separated_string = ( join(",",@$Value) );
                            readingsBulkUpdate($hash,$Reading,$comma_separated_string);
                            $allreadings->{$Reading} = $comma_separated_string;
                            Log3($name,5,$name." - ".$Reading." ".$comma_separated_string." (".$Type.")");
                        }
                        else {
                            Log3($name,4,$name." - Array Workaround for Property: ".$Reading);
                        }
                    }
                }
                elsif ($Type eq 'object') {
                    # Iteriere durch die Schlüssel des Hashes
                    foreach my $hash_key (sort keys %$Value) {
                        my $hash_value = $Value->{$hash_key};
                        $comma_separated_string .= $hash_value . ", ";
                    }
                    # Entferne das letzte Komma und Leerzeichen
                    $comma_separated_string =~ s/, $//;
                    readingsBulkUpdate($hash,$Reading,$comma_separated_string);
                    $allreadings->{$Reading} = $comma_separated_string;
                }
                elsif ( $Type eq "Schedule" ) {
                    my @schedule;
                    foreach my $day (@days) {
                     if (exists $Value->{$day}) {
                       foreach my $entry (@{$Value->{$day}}) {
                         my $ordered_entry = sprintf('{"mode":"%s","start":"%s","end":"%s","position":%d}',
                                             $entry->{mode}, $entry->{start}, $entry->{end}, $entry->{position}
                       );
                       push @schedule, sprintf('{"%s":%s}', $day, $ordered_entry);
                       }
                     }
                    }
                    my $Result = '[' . join(',', @schedule) . ']';
                    readingsBulkUpdate($hash, $Reading, $Result);
                    $allreadings->{$Reading} = $Result;
                    Log3($name, 5, "$name - $Reading: $Result ($Type)");
                }
                else {
                    readingsBulkUpdate($hash,$Reading,$Value);
                    $allreadings->{$Reading} = $Value;
                    Log3 $name, 5, "$name - $Reading: $Value ($Type)";
                    #Log3 $name, 1, "$name - $Reading: $Value ($Type)";
                }
                
                # Store power readings as asSingleValue
                if ($Reading =~ m/dayValueReadAt$/) {
                 Log(5,$name.", -call setpower $Reading");
                 vitoconnect_getPowerLast ($hash,$name,$Reading);
                }
                
                # Get error codes from API
                if ($Reading eq "device.messages.errors.raw.entries") {
                 Log(5,$name.", -call getErrorCode $Reading");
                 if (defined $comma_separated_string && $comma_separated_string ne '') {
                  vitoconnect_getErrorCode ($hash,$name,$comma_separated_string);
                 }
                }
            }
        }

        readingsBulkUpdate($hash,"state","last update: ".TimeNow().""); # Reading 'state'
        readingsEndUpdate( $hash, 1 );  # Readings schreiben
    }
    else {
        Log3($name,1,$name." - An error occured: ".$err);
    }
      
    InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
    Log(5,$name.", -getResourceCallback ended");
    
    vitoconnect_Client_Update_Readings($hash, $allreadings);
    
    return;
}

sub vitoconnect_Client_Update_Readings {
    my $serverHash = shift // return;
    my $readings   = shift // return;
    
    for my $client ( devspec2array("TYPE=vitoconnect:FILTER=i:SERVER=$serverHash->{NAME}") ) {
        my $hash = $defs{$client} // next;
        readingsBeginUpdate($hash);
        my $readingName;
        my $updated = 0;
        for my $reading ( keys %{$readings} ) {
            $readingName = $reading if $reading =~ m{$hash->{subset}};
            if ( defined $hash->{helper} && defined $hash->{helper}->{mappings} && defined $hash->{helper}->{mappings}->{$reading} ) {
                $readingName = $hash->{helper}->{mappings}->{$reading};
            }
            next if !$readingName;           # not defined or 0
            readingsBulkUpdate($hash,$readingName,$readings->{$reading},1);
            $updated = 1;
            $readingName = undef;
        }
        readingsEndUpdate( $hash, $updated );  # Readings schreiben
    }
    return;
}



#####################################################################################################################
# Implementierung power readings die nur sehr selten kommen in ein logbares reading füllen (asSingleValue)
#####################################################################################################################
sub vitoconnect_getPowerLast {
    my ($hash, $name, $Reading) = @_;

    # entferne alles hinter dem letzten Punkt
    $Reading =~ s/\.[^.]*$//;
    
    # Liste der Stromwerte
    my @values = split(",", ReadingsVal($name,$Reading.".day","")); #(1.2, 76.7, 52.6, 40.9, 40.4, 30, 33.9, 75);

    # Zeitpunkt des ersten Wertes
    my $timestamp = ReadingsVal($name,$Reading.".dayValueReadAt",""); #'2024-11-29T11:28:56.915Z';

    if (!defined($timestamp)) {
        return;
    }

    # Datum extrahieren und in ein Time::Piece Objekt umwandeln
    my $date = Time::Piece->strptime(substr($timestamp, 0, 10), '%Y-%m-%d');

    # Anzahl der Sekunden in einem Tag
    my $one_day = 24 * 60 * 60;
    
    # Hash für die Key-Value-Paare
    my %data;
    my $readingLastTimestamp = ReadingsTimestamp($name,$Reading.".day.asSingleValue","0000000000");
    #my $lastTS = "0000000000";
    #if ($readingLastTimestamp ne "") {
    my $lastTS = time_str2num($readingLastTimestamp);
    #}
    Log(5,$name.", -setpower: readinglast: $readingLastTimestamp lastTS $lastTS");
    
    # Werte den entsprechenden Tagen zuordnen, start mit 1, letzten Tag ausschließen weil unvollständig
    for (my $i = $#values; $i >= 1; $i--) {
        my $current_date = $date - ($one_day * $i);
        Log3($name, 5, ", -setpower: date:$current_date value:$values[$i] ($i)");
        my $readingDate = $current_date->ymd . " 23:59:59";
        my $readingTS = time_str2num($readingDate);
        Log(5,$name.", -setpower: date $readingDate lastdate $readingLastTimestamp");
        if ($readingTS > $lastTS) {
         readingsBulkUpdate ($hash, $Reading.".day.asSingleValue", $values[$i], undef, $readingDate);
         Log(4,$name.", -setpower: readingsBulkUpdate ($hash, $Reading.day.asSingleValue, $values[$i], undef, $readingDate");
        }
    }

    return;
}


#####################################################################################################################
# Error Code auslesesn
#####################################################################################################################
sub vitoconnect_getErrorCode {
    my ($hash, $name, $comma_separated_string) = @_;
    #$comma_separated_string = "customer, c2, warning, 2025-02-03T17:25:19.000Z"; # debug
    my $language = AttrVal( 'global', 'language', 0 );
    my %severity_translations = (
    'note'          => 'Hinweis',
    'warning'       => 'Warnung',
    'error'         => 'Fehler',
    'criticalError' => 'kritischer Fehler'
     );

    if (defined $comma_separated_string && $comma_separated_string ne '') {

        my $serial = ReadingsVal($name, "device.serial.value", "");
        my $materialNumber = substr($serial, 0, 7); #"7733738"; #debug
        my @values = split(/, /, $comma_separated_string);
        my $Reading = "device.messages.errors.mapped";

        my $fault_counter = -1;
        my $cause_counter = -1;
        
        for (my $i = 0; $i < @values; $i += 4) {
            my $errorCode = $values[$i + 1];
            my $severity = $values[$i + 2];
            if (uc($language) eq 'DE') {
            $severity = $severity_translations{$severity};
            }

            my $param = {
                url => "${vitoconnect_errorURL_V3}?materialNumber=$materialNumber&errorCode=$errorCode&countryCode=${\uc($language)}&languageCode=${\lc($language)}",
                hash => $hash,
                timeout => $hash->{timeout},  # Timeout von Internals = 15s
                method => "GET",  # Methode auf GET ändern
                sslargs => { SSL_verify_mode => 0 },
            };
            Log3($name, 5, "$name, vitoconnect_getErrorCode url=$param->{url}");

            my ($err, $msg) = HttpUtils_BlockingGet($param);

            if (defined($err) && $err ne '') {   # Fehler bei Befehlsausführung
                Log3($name, 1, "$name, vitoconnect_getErrorCode call finished with error, err: $err");
                return;
            }

            my $decoded_json;

            if ( !eval { $decoded_json = JSON->new->decode($msg) ; 1 } ) {
                Log3($hash->{NAME}, 1, "JSON decoding error: $@");
                return "API seems not to return valid JSON: $@";
            }
            return if !defined $decoded_json;
            #Log3($name, 5, $name . ", vitoconnect_getErrorCode debug err=$err msg=" . $msg . " json=" . Dumper($decode_json));  # wieder weg
            
            if (exists $decoded_json->{statusCode} && $decoded_json->{statusCode} ne '') {
                Log3($name, 1, "$name, vitoconnect_getErrorCode call finished with error, status code: $decoded_json->{statusCode}");
            } else {   # Befehl korrekt ausgeführt
                Log3($name, 5, $name . ", vitoconnect_getErrorCode: finished ok");
                if (exists $decoded_json->{faultCodes} && @{$decoded_json->{faultCodes}}) {
                    foreach my $fault (@{$decoded_json->{faultCodes}}) {
                        $fault_counter++;
                        my $fault_code = $fault->{faultCode};
                        my $system_characteristics = $fault->{systemCharacteristics};
                        # remove html paragraphs
                        $system_characteristics =~ s/<\/?(p|q)>//g;
                        readingsBulkUpdate($hash, $Reading . ".$fault_counter.faultCode", $fault_code);
                        readingsBulkUpdate($hash, $Reading . ".$fault_counter.severity", $severity);
                        readingsBulkUpdate($hash, $Reading . ".$fault_counter.systemCharacteristics", $system_characteristics);

                        foreach my $cause (@{$fault->{causes}}) {
                            $cause_counter++;
                            my $cause_text = $cause->{cause};
                            my $measure = $cause->{measure};
                            # remove html paragraphs
                            $cause_text =~ s/<\/?(p|q)>//g;
                            $measure =~ s/<\/?(p|q)>//g;
                            readingsBulkUpdate($hash, $Reading . ".$fault_counter.faultCodes.$cause_counter.cause", $cause_text);
                            readingsBulkUpdate($hash, $Reading . ".$fault_counter.faultCodes.$cause_counter.measure", $measure);
                        }
                    }
                } else {
                    Log3($name, 1, $name . ", vitoconnect_getErrorCode no faultcode in json found. json=" . Dumper($decoded_json));
                }
            }
        }
    } else {
        Log3($name, 1, $name . " , vitoconnect_getErrorCode the variable \$comma_separated_string does not exist or is empty");
    }
    return;
}

#####################################################################################################################
# Setzen von Daten über Timer
#####################################################################################################################
sub vitoconnect_actionTimerWrapper {
    my ($argRef) = @_;
    
    return vitoconnect_action(@$argRef) if ref $argRef eq 'ARRAY';
    
    my $type = ref $argRef // 'undef';
    my $name = ref $argRef eq 'HASH' ? $argRef->{NAME} // 'unknown' : 'unknown';
    Log3($name, 1, "$name - vitoconnoct_actionTimerWrapper: Fehlerhafte Argumentübergabe (Typ: $type), erwartet ARRAY-Referenz");
    return;
}


#####################################################################################################################
# Setzen von Daten
#####################################################################################################################
sub vitoconnect_action {
    my ($hash,$feature,$data,$name,$opt,@args ) = @_;
    my $access_token = $hash->{'.access_token'};
    my $installation = AttrVal( $name, 'vitoconnect_installationID', 0 );
    my $gw           = AttrVal( $name, 'vitoconnect_serial', 0 );
    my $dev          = AttrVal($name,'vitoconnect_device',0);
    my $Text         = join ' ', @args;
    my $retry_count  = $hash->{'.action_retry_count'} // 0;

    my $param        = {
        url => "${vitoconnect_iotURL_V2}installations/$installation/gateways/$gw/devices/$dev/features/$feature",
        hash   => $hash,
        header => "Authorization: Bearer $access_token\r\nContent-Type: application/json",
        data    => $data,
        timeout => $hash->{timeout},
        method  => "POST",
        sslargs => { SSL_verify_mode => 0 },
    };
    Log3($name,3,$name.", vitoconnect_action url=" .$param->{url}); # change back to 3
    Log3($name,3,$name.", vitoconnect_action data=".$param->{data}); # change back to 3
#   https://wiki.fhem.de/wiki/HttpUtils#HttpUtils_BlockingGet
    (my $err,my $msg) = HttpUtils_BlockingGet($param);
    #my $decode_json = eval {decode_json($msg)};
    my $decoded_json;
    if ( !eval { $decoded_json = JSON->new->decode($msg) ; 1 } ) {
        Log3($hash->{NAME}, 1, "JSON decoding error: $@");
            return "API seems not to return valid JSON: $@";
        }
    return if !defined $decoded_json;

    Log3($name,3,$name.", vitoconnect_action call finished, err:" .$err) if $err;
    my $Text = join(' ',@args); # Befehlsparameter in Text
    if ( (defined($err) && $err ne "") || (defined($decoded_json->{statusCode}) && $decoded_json->{statusCode} ne "") )                   {   # Fehler bei Befehlsausführung
        $retry_count++;
        $hash->{'.action_retry_count'} = $retry_count;
        readingsSingleUpdate($hash, "Aktion_Status", "Fehler ($retry_count/20): $opt $Text", 1);
        Log3($name,1,"$name,vitoconnect_action: set $name $opt @args, Fehler bei Befehlsausfuehrung ($retry_count/20): $err :: $msg");

        # Token abgelaufen?
        if ($decoded_json->{statusCode} eq '401' && $decoded_json->{error} eq 'EXPIRED TOKEN') {
            # Token erneuern, aber ohne getResource
            $hash->{'.retry_feature'}      = $feature;
            $hash->{'.retry_data'}         = $data;
            $hash->{'.retry_opt'}          = $opt;
            $hash->{'.retry_args'}         = [@args];
            $hash->{'.action_retry_count'} = $retry_count;
            vitoconnect_getRefresh($hash, 'action');  # Kontext 'action' → kein getResource
            return;
        }

        # Wiederholen in 10 Sekunden
        if ($retry_count < 20) {
          InternalTimer(gettimeofday() + 10, "vitoconnect_actionTimerWrapper", [$hash, $feature, $data, $name, $opt, @args]);
        } else {
            Log3($name, 1, "$name - vitoconnect_action: Abbruch nach 20 Fehlversuchen");
            readingsSingleUpdate($hash, "Aktion_Status", "Fehlgeschlagen: $opt $Text (nach 20 Versuchen)", 1);
            # Abbruch nach 20 versuchen → Retry-Zähler und Daten zurücksetzen
            delete $hash->{'.action_retry_count'};
            delete $hash->{'.retry_feature'};
            delete $hash->{'.retry_data'};
            delete $hash->{'.retry_opt'};
            delete $hash->{'.retry_args'};
        }
        return;
#        readingsSingleUpdate($hash,"Aktion_Status","Fehler: ".$opt." ".$Text,1);    # Reading 'Aktion_Status' setzen
#        Log3($name,1,$name.",vitoconnect_action: set ".$name." ".$opt." ".@args.", Fehler bei Befehlsausfuehrung: ".$err." :: ".$msg);
    }
    else                                                                {   # Befehl korrekt ausgeführt
        #readingsSingleUpdate($hash,"Aktion_Status","OK: ".$opt." ".$Text,1);    # Reading 'Aktion_Status' setzen
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash,'Aktion_Status',"OK: $opt $Text");
        #Log3($name,1,$name.",vitoconnect_action: set name:".$name." opt:".$opt." text:".$Text.", korrekt ausgefuehrt: ".$err." :: ".$msg); # TODO: Wieder weg machen $err
        Log3($name,3,$name.",vitoconnect_action: set name:".$name." opt:".$opt." text:".$Text.", korrekt ausgefuehrt"); 
        
        # Spezial Readings update
        if ($opt =~ /(.*)\.deactivate/) {
            $opt = $1 . ".active";
            $Text = "0";
        } elsif ($opt =~ /(.*)\.activate/) {
            $opt = $1 . ".active";
            $Text = "1";
        }
        #readingsSingleUpdate($hash,$opt,$Text,1);   # Reading updaten
        readingsBulkUpdate($hash,$opt,$Text);   # Reading updaten
        #Log3($name,1,$name.",vitoconnect_action: reading upd1 hash:".$hash." opt:".$opt." text:".$Text); # TODO: Wieder weg machen $err
        
        # Spezial Readings update, activate mit temperatur siehe brenner Vitoladens300C
        if ($feature =~ /(.*)\.deactivate/) {
            # funktioniert da deactivate ohne temperatur gesendet wird
        } elsif ($feature =~ /(.*)\/commands\/activate/) {
            $opt = $1 . ".active";
            $Text = "1";
        }
        #readingsSingleUpdate($hash,$opt,$Text,1);   # Reading updaten
        readingsBulkUpdate($hash,$opt,$Text);
        #Log3($name,1,$name.",vitoconnect_action: reading upd2 hash:".$hash." opt:".$opt." text:".$Text); # TODO: Wieder weg machen $err
        readingsEndUpdate($hash, 1);


        Log3($name,4,"$name,vitoconnect_action: set feature: $feature data: $data, korrekt ausgefuehrt"); #4
        delete $hash->{'.action_retry_count'};
        delete $hash->{'.retry_feature'};
        delete $hash->{'.retry_data'};
        delete $hash->{'.retry_opt'};
        delete $hash->{'.retry_args'};

    }
    return;
}


#####################################################################################################################
# Errors bearbeiten
#####################################################################################################################
sub vitoconnect_errorHandling {
    my ($hash,$items) = @_;
    my $name          = $hash->{NAME};
    my $gw            = AttrVal( $name, 'vitoconnect_serial', 0 );
    
    #Log3 $name, 1, "$name - errorHandling StatusCode: $items->{statusCode} ";
    
        if (defined $items->{statusCode} && !$items->{statusCode} eq "")    {
            Log3 $name, 4, "$name - statusCode: " . ($items->{statusCode} // 'undef') . " "
                         . "errorType: " . ($items->{errorType} // 'undef') . " "
                         . "message: " . ($items->{message} // 'undef') . " "
                         . "error: " . ($items->{error} // 'undef') . " "
                         . "reason: " . ($items->{extendedPayload}->{reason} // 'undef');
             
            readingsSingleUpdate(
               $hash,
               "state",
               "statusCode: " . ($items->{statusCode} // 'undef') . " "
             . "errorType: " . ($items->{errorType} // 'undef') . " "
             . "message: " . ($items->{message} // 'undef') . " "
             . "error: " . ($items->{error} // 'undef') . " "
             . "reason: " . ($items->{extendedPayload}->{reason} // 'undef'),
               1
            );
            if ( $items->{statusCode} eq "401" ) {
                #  EXPIRED TOKEN
                vitoconnect_getRefresh($hash, 'update');    # neuen Access-Token anfragen
                return(1);
            }
            if ( $items->{statusCode} eq "404" ) {
                # DEVICE_NOT_FOUND
                readingsSingleUpdate($hash,"state","Device not found: Optolink prüfen!",1);
                Log3 $name, 1, "$name - Device not found: Optolink prüfen!";
                InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
                return(1);
            }
            if ( $items->{statusCode} eq "429" ) {
                # RATE_LIMIT_EXCEEDED
                readingsSingleUpdate($hash,"state",'Anzahl der möglichen API Calls überschritten!',1);
                Log3 $name, 1,
                  "$name - Anzahl der möglichen API Calls überschritten, memoryadress: $hash!";
                InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
                return(1);
            }
            if ( $items->{statusCode} eq "502" ) {
                readingsSingleUpdate($hash,"state","temporärer API Fehler",1);
                # DEVICE_COMMUNICATION_ERROR error: Bad Gateway
                Log3 $name, 1, "$name - temporärer API Fehler";
                InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
                return(1);
            }
            
            readingsSingleUpdate($hash,"state","unbekannter Fehler, bitte den Entwickler informieren! (Typ: "
                 . ($items->{errorType} // 'undef') . " Grund: "
                 . ($items->{extendedPayload}->{reason} // 'NA') . ")",1);
            Log3 $name, 1, "$name - unbekannter Fehler: "
                 . "Bitte den Entwickler informieren!";
            Log3 $name, 1, "$name - statusCode: " . ($items->{statusCode} // 'undef') . " "
                 . "errorType: " . ($items->{errorType} // 'undef') . " "
                 . "message: " . ($items->{message} // 'undef') . " "
                 . "error: " . ($items->{error} // 'undef') . " "
                 . "reason: " . ($items->{extendedPayload}->{reason} // 'undef');

            my $dir         = path( AttrVal("global","logdir","log"));
            my $file        = $dir->child("vitoconnect_" . $gw . ".err");
            my $file_handle = $file->openw_utf8();
            $file_handle->print(Dumper($items));                            # Datei 'vitoconnect_serial.err' schreiben
            $file_handle->close();
            Log3($name,3,$name." Datei: ".$dir."/".$file." geschrieben");

            InternalTimer(gettimeofday() + $hash->{interval},"vitoconnect_GetUpdate",$hash);
            return(1);
        }
};

sub vitoconnect_Rename {
    my ($new, $old) = @_;
    for my $element ( qw ( apiKey passwd ) ) {
        my $val = vitoconnect_ReadKeyValue($old,$element);
        vitoconnect_StoreKeyValue($new,$element,$val);
    }
    vitoconnect_DeleteKeyValue($old);

}
#####################################################################################################################
# Werte verschlüsselt speichern
#####################################################################################################################
sub vitoconnect_StoreKeyValue {
    # checks and stores obfuscated keys like passwords
    # based on / copied from FRITZBOX_storePassword
    my ( $name, $kName, $value ) = @_;
    my $index = "vitoconnect_${name}_$kName";
    my $key   = getUniqueId().$index;
    my $enc   = "";

    if ( eval "use Digest::MD5;1" ) {
        $key = Digest::MD5::md5_hex( unpack "H*", $key );
        $key .= Digest::MD5::md5_hex($key);
    }
    for my $char ( split //, $value ) {
        my $encode = chop($key);
        $enc .= sprintf( "%.2x", ord($char) ^ ord($encode) );
        $key = $encode . $key;
    }
    my $err = setKeyValue( $index, $enc );      # Die Funktion setKeyValue() speichert die Daten $value unter dem Schlüssel $key ab.
    return "error while saving the value - ".$err if ( defined($err) ); # Fehler
    return;
}


#####################################################################################################################
# verschlüsselte Werte auslesen
#####################################################################################################################
sub vitoconnect_ReadKeyValue {

    # reads obfuscated value

    my ($name,$kName) = @_;     # Übergabe-Parameter
    
    my $index = "vitoconnect_${name}_".$kName;
    my $key   = getUniqueId().$index;

    my ( $value, $err );

    Log3($name,5,$name." - ReadKeyValue tries to read value for ".$kName." from file");
    ($err,$value ) = getKeyValue($index);       # Die Funktion getKeyValue() gibt Daten, welche zuvor per setKeyValue() gespeichert wurden, zurück.

    if ( defined($err) )    {   # im Fehlerfall
        Log3($name,1,$name." - ReadKeyValue is unable to read value from file: ".$err);
        return;
    }

    if ( defined($value) )  {
        if ( eval "use Digest::MD5;1" ) {
            $key = Digest::MD5::md5_hex( unpack "H*", $key );
            $key .= Digest::MD5::md5_hex($key);
        }
        my $dec = '';
        for my $char ( map  { pack( 'C', hex($_) ) } ( $value =~ /(..)/g ) ) {
            my $decode = chop($key);
            $dec .= chr( ord($char) ^ ord($decode) );
            $key = $decode . $key;
        }
        return $dec;            # Rückgabe dekodierten Wert
    }
    else                    {   # Fehler: 
        Log3($name,1,$name." - ReadKeyValue could not find key ".$kName." in file");
        return;
    }
    return;
}


#####################################################################################################################
# verschlüsselte Werte löschen
#####################################################################################################################
sub vitoconnect_DeleteKeyValue {
    my ($name) = @_;    # Übergabe-Parameter
    
    Log3( $name, 5,$name." - called function Delete()" );

    my $index = "vitoconnect_${name}_passwd";
    setKeyValue( $index, undef );
    $index = "vitoconnect_${name}_apiKey";
    setKeyValue( $index, undef );

    return;
}

sub vitoconnect_readConfFile {
    my $hash     = shift // return;
    delete $hash->{'.sets'};
    my $filename = shift // AttrVal($hash->{NAME},'confFile',undef) // return 'no filename provided';

    my $name = $hash->{NAME};
    my ($ret, @content) = FileRead($filename);
    if ($ret) {
        Log3($name, 1, "$name failed to read confFile $filename!") ;
        return $ret;
    }
    my @cleaned = grep { $_ !~ m{\A\s*[#]}x } @content;
    for (@cleaned) {
        $_ =~ s{\A\s+}{}gmxsu;
    };
    my $decoded;
    if ( !eval { $decoded  = JSON->new->decode(join q{ }, @cleaned) ; 1 } ) {
        Log3($hash->{NAME}, 1, "JSON confFile $filename: $@");
        return "confFile $filename seems not to contain valid JSON!";
    }
    return if !defined $decoded;
    return "confFile $filename: JSON seems not to contain valid key-value pairs!" if ref $decoded ne 'HASH';

#    Log3($name, 3, "$name confFile has " . (keys %{$decoded}) . 'keys' ) ;

    for ( keys %{$decoded} ) {
#        next if ref $decoded->{$_} ne 'SCALAR';
        $hash->{helper}->{mappings}->{$_} = $decoded->{$_};
    }

    #https://forum.fhem.de/index.php?topic=95375.0
    $data{confFiles}{$filename} = 0;
    return;
}

sub vitoconnect_send_weekprofile {
    my $name       = shift // Carp::carp q[No device name provided!]              && return;
    my $wp_name    = shift // Carp::carp q[No weekprofile device name provided!]  && return;
    my $wp_profile = shift // AttrVal($name, 'weekprofile', undef) // Carp::carp q[No weekprofile profile name provided!] && return;
    my $entity     = shift // '0.heating';  #might be one of (0-2).(heating|circulation), dhw or dhw.pumps?
  
    my $hash = $defs{$name} // return;
  
    my $wp_profile_data = CommandGet(undef,"$wp_name profile_data $wp_profile 0");
    if ($wp_profile_data =~ m{(profile.*not.found|usage..profile_data..name)}xms ) {
        Log3( $hash, 3, "[$name] weekprofile $wp_name: no profile named \"$wp_profile\" available" );
        return "[$name] weekprofile $wp_name: no profile named \"$wp_profile\" available";
    }

    my @D = qw(Sun Mon Tue Wed Thu Fri Sat); # eqals to my @D = ("Sun","Mon","Tue","Wed","Thu","Fri","Sat");
    my $lim2;
    $lim2 = 20 if $entity =~ m{\A..heating\z}x;
    my $payload = '[';
    my @days = (1..6,0); # vitoconnect starts week with monday...
    my $decoded;
    if ( !eval { $decoded  = JSON->new->decode($wp_profile_data) ; 1 } ) {
        Log3($name, 1, "JSON decoding error in $wp_profile provided by $wp_name: $@");
        return;
    }

    for my $i (@days) {
        my $oldval = 'off';
        my $position = 0;
        my $start;
        my $dayname = lc $D[$i];
        #$payload .= qq({"$dayname":); #{"mon":
        my $val;

        for my $j (0..20) {
            my $time;
            if (defined $decoded->{$D[$i]}{time}[$j]) {
                $time = $decoded->{$D[$i]}{time}[$j-1] // '00:00';
                if ( !$j ) {    #first value
                    $time = '00:00';
                }

                $val = $decoded->{$D[$i]}{temp}[$j];
        #Log3($name, 1, "test: $dayname entry $j starts $time with $val");

                $val = vitoconnect_compareOnOff($val,$oldval,22,$lim2);
                if ( $j == 20 ) {    #last value, force closing
                    $time = '24:00';
                    $val = 'off' ;
                }
            } else { #no more entries in profile
                $time = '24:00';
                $val = 'off' ;

            }
            next if !defined $val;   #nothing's changed

            if ( $val ne $oldval ) {
        #Log3($name, 1, "test: $dayname entry $j changed to $val");
                if ($oldval eq 'off') {
                    $time = '00:00' if !$j;
                } else {
                    # "position" is complete, we need something like:
                    # {"mode":"normal","start":"05:50","end":"16:00","position":0}

                    #nr of positions is limited to 4 (0-3)
                    if ( $position == 4 ) {
                        Log3($name,2,"vitoconnect only accepts 4 positions, check your weekprofiles!");
                        return "Error:vitoconnect only accepts 4 positions, check your weekprofile $wp_name: $wp_profile!";
                    }
                    $payload .= qq({"$dayname":{"mode":"$oldval","start":"$start","end":"$time","position":$position}},);
                    $position++;
                }
                $start = $time;
                $oldval = $val;
            }
            last if !defined $decoded->{$D[$i]}{time}[$j]

        }
        if (!$position) {    #prevent empty entry, so we set some defaults!
            if ( !defined $lim2 ) {
                $payload .= qq({"$dayname":{"mode":"on","start":"05:30","end":"21:30","position":0}},);
            } else {
                $payload .= qq({"$dayname":{"mode":"normal","start":"06:00","end":"22:00","position":0}},);
            }
        }
    }
    chop $payload; # remove last ","
    $payload .= ']';
    return if $payload eq ReadingsVal($name, "heating.circuits.${entity}.schedule.entries",'');
    #for heating types only; we will have to check that...
        
    if( $entity =~ m{\d+.heating}x ) {
        vitoconnect_action($hash,
            "heating.circuits.${entity}.schedule/commands/setSchedule",
                #qq({"newSchedule":$schedule_data}),
                qq({"newSchedule":$payload}),
                $name,"heating.circuits.${entity}.schedule",$payload #might no longer be $payload but $schedule_data
            );
    } else {
        # Beta-User: correct vitoconnect_action has to be completed, this should at least work for "dhw"...
        # heating.dhw.schedule.entries
        vitoconnect_action($hash,
            "heating.${entity}.schedule/commands/setSchedule",
                #qq({"newSchedule":$schedule_data}),
                qq({"newSchedule":$payload}),
                $name,"heating.${entity}.schedule",$payload #might no longer be $payload but $schedule_data
            );
        #readingsSingleUpdate( $hash, 'weekprofile_send_data', $payload,1);
    }
    readingsSingleUpdate( $hash, 'weekprofile', "$wp_name $wp_profile",1);
    return;
}


=pod
allowed positions: 0-3 (all schedules)
(HK1_Zeitsteuerung_Heizung)
heating.circuits.0.heating.schedule.entries [{"mon":{"mode":"normal","start":"05:50","end":"22:00","position":0}},{"tue":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"wed":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"thu":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"fri":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"sat":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"sun":{"mode":"normal","start":"06:00","end":"22:00","position":0}}]
heating.circuits.0.heating.schedule.entries [{"mon":{"mode":"normal","start":"05:50","end":"22:00","position":0}},{"tue":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"wed":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"thu":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"fri":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"sat":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"sun":{"mode":"normal","start":"06:00","end":"22:00","position":0}}]
[{"mon":{"mode":"normal","start":"05:50","end":"16:00","position":0}},{"mon":{"mode":"comfort","start":"16:00","end":"21:30","position":1}},{"mon":{"mode":"normal","start":"21:30","end":"22:00","position":2}},{"tue":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"wed":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"thu":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"fri":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"sat":{"mode":"normal","start":"06:00","end":"22:00","position":0}},{"sun":{"mode":"normal","start":"06:00","end":"22:00","position":0}}]
first approach: 
every temp below 20 degrees is "eco" (not to be included in array, just "end" trigger)
every temp starting with 22 degrees is "comfort" 
all in the middle are "normal"
(might be adopted later to readingVal() requests?) 
(WW_Zeitplan)
heating.dhw.schedule.entries [{"mon":{"mode":"on","start":"05:30","end":"22:00","position":0}},{"tue":{"mode":"on","start":"05:30","end":"22:00","position":0}},{"wed":{"mode":"on","start":"05:30","end":"22:00","position":0}},{"thu":{"mode":"on","start":"05:30","end":"22:00","position":0}},{"fri":{"mode":"on","start":"05:30","end":"22:00","position":0}},{"sat":{"mode":"on","start":"05:30","end":"22:00","position":0}},{"sun":{"mode":"on","start":"05:30","end":"22:00","position":0}}]
periodes outside "on" are just "off"
first approach: every temp starting with 22 degrees is "on"

=cut


sub vitoconnect_compareOnOff {
    my $val    = shift // return;
    my $oldval = shift // return;
    my $lim1   = shift // 22;
    my $lim2   = shift;

    if (looks_like_number($val)) { #numeric comparison
        if ( $val >= $lim1 ) {
            return if $oldval eq 'on' || $oldval eq 'comfort';
            return 'comfort' if defined $lim2;
            return 'on';
        }
        if ( !defined $lim2 || $val < $lim2) {
            return if $oldval eq 'off';
            return 'off';
        }
        return if $oldval eq 'normal';
        return 'normal';
    }

    return if $oldval eq $val;
    return $val;
}


1;

__END__

=pod
=item device
=item summary support for Viessmann API
=item summary_DE Unterstützung für die Viessmann API
=begin html

<a id="vitoconnect"></a>
<h3>vitoconnect</h3>
<ul>
    <i>vitoconnect</i> implements a device for the Viessmann API
    <a href="https://www.viessmann.de/de/viessmann-apps/vitoconnect.html">Vitoconnect100</a> or E3 One Base
    based on the investigation of
    <a href="https://github.com/thetrueavatar/Viessmann-Api">thetrueavatar</a>.<br>
    
    You need the user and password from the ViCare App account.<br>
    Additionally also an apiKey, see set apiKey.<br>
     
    For details, see: <a href="https://wiki.fhem.de/wiki/Vitoconnect">FHEM Wiki (German)</a><br><br>
     
    vitoconnect requires the following libraries:
    <ul>
        <li>Path::Tiny</li>
        <li>JSON</li>
        <li>JSON:XS</li>
        <li>DateTime</li>
    </ul>   
         
    Use <code>sudo apt install libtypes-path-tiny-perl libjson-perl libdatetime-perl</code> or 
    install the libraries via CPAN. 
    Otherwise, you will get an error message: "cannot load module vitoconnect".
     
    <br><br>
    <a id="vitoconnect-define"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; vitoconnect &lt;user&gt; &lt;password&gt; &lt;interval&gt;</code><br>
        You may also hand over arguments as named list like
        <code>define &lt;name&gt; vitoconnect &lt;user=your_API_user&gt; &lt;password=your_password&gt; &lt;apiKey=yourAPIkey&gt; &lt;interval=60&gt;</code><br>
        If provided, password and apiKey will be stored elswhere and then be removed from the definition.
        <br>
        If not specified, 300 seconds will be used as interval.
        <br><br>
        Example:<br>
        <code>define vitoconnect vitoconnect user@mail.xx password=somesecretthing apiKey=someothersecret 60</code><br>
        Otherwise, you may use the set commands later<br>
        <code>set vitoconnect password correctPassword</code>
        <code>set vitoconnect apiKey Client-ID</code>
        <br><br>
    </ul>
    <br>
    
    <a id="vitoconnect-set"></a>
    <b>Set</b><br>
    <ul>
        <a id="vitoconnect-set-update"></a>
        <li><code>update</code><br>
            Update readings immediately.</li>
        <a id="vitoconnect-set-selectDevice"></a>
        <li><code>selectDevice</code><br>
            Has to be used if you have more than one Viessmann Gateway/Device. You have to choose one Viessmann Device per FHEM Device.<br>
            You will be notified in the FHEM device state that you have to execute the set, and the Viessmann devices will be prefilled.<br>
            Selecting one Viessmann device and executing the set will fill the attributes <code>vitoconnect_serial</code> and <code>vitoconnect_installationId</code>.<br>
            If you have only one Viessmann device, this will be done automatically for you.<br>
            You should save the change after initialization or set.
        </li>
        <a id="vitoconnect-set-clearReadings"></a>
        <li><code>clearReadings</code><br>
            Clear all readings immediately.</li> 
        <a id="vitoconnect-set-clearMappedErrors"></a>
        <li><code>clearMappedErrors</code><br>
            Clear all mapped errors immediately.</li> 
        <a id="vitoconnect-set-password"></a>
        <li><code>password passwd</code><br>
            Store password in the key store.</li>
        <a id="vitoconnect-set-logResponseOnce"></a>
        <li><code>logResponseOnce</code><br>
            Dumps the JSON response of the Viessmann server to <code>entities.json</code>,
            <code>gw.json</code>, and <code>actions.json</code> in the FHEM log directory.
            If you have more than one gateway, the gateway serial is attached to the filenames.</li>
        <a id="vitoconnect-set-apiKey"></a>
        <li><code>apiKey</code><br>
            You need to create an API Key under <a href="https://developer.viessmann-climatesolutions.com/">https://developer.viessmann-climatesolutions.com/</a>.
            Create an account, add a new client (disable Google reCAPTCHA, Redirect URI = <code>http://localhost:4200/</code>).
            Copy the Client ID here as <code>apiKey</code>.</li>
        <li><code>Setters for your device will be available depending on the mapping method you choose with the help of the attributes <code>vitoconnect_raw_readings</code> or <code>vitoconnect_mapping_roger</code>.</code><br>
            New setters are used if <code>vitoconnect_raw_readings = 1</code>.
            The default is the static mapping of the old SVN version.
            For this, the following setters are available:</li>
        <li><code>HKn_Heizkurve_Niveau shift</code><br>
            Set shift of heating curve for HKn.</li>
        <li><code>HKn_Heizkurve_Steigung slope</code><br>
            Set slope of heating curve for HKn.</li>
        <li><code>HKn_Urlaub_Start_Zeit start</code><br>
            Set holiday start time for HKn.<br>
            <code>start</code> has to look like this: <code>2019-02-02</code>.</li>
        <li><code>HKn_Urlaub_Ende_Zeit end</code><br>
            Set holiday end time for HKn.<br>
            <code>end</code> has to look like this: <code>2019-02-16</code>.</li>
        <li><code>HKn_Urlaub_stop</code> <br>
            Remove holiday start and end time for HKn.</li>
        <li><code>HKn_Zeitsteuerung_Heizung schedule</code><br>
            Sets the heating schedule for HKn in JSON format.<br>
            Example: <code>{"mon":[],"tue":[],"wed":[],"thu":[],"fri":[],"sat":[],"sun":[]}</code> is completely off,
            and <code>{"mon":[{"mode":"on","start":"00:00","end":"24:00","position":0}],
            "tue":[{"mode":"on","start":"00:00","end":"24:00","position":0}],
            "wed":[{"mode":"on","start":"00:00","end":"24:00","position":0}],
            "thu":[{"mode":"on","start":"00:00","end":"24:00","position":0}],
            "fri":[{"mode":"on","start":"00:00","end":"24:00","position":0}],
            "sat":[{"mode":"on","start":"00:00","end":"24:00","position":0}],
            "sun":[{"mode":"on","start":"00:00","end":"24:00","position":0}]}</code> is on 24/7.</li>
        <li><code>HKn_Betriebsart heating,standby</code> <br>
            Sets <code>HKn_Betriebsart</code> to <code>heating</code> or <code>standby</code>.</li>
        <li><code>WW_Betriebsart balanced,off</code> <br>
            Sets <code>WW_Betriebsart</code> to <code>balanced</code> or <code>off</code>.</li>
        <li><code>HKn_Soll_Temp_comfort_aktiv activate,deactivate</code> <br>
            Activate/deactivate comfort temperature for HKn.</li>
        <li><code>HKn_Soll_Temp_comfort targetTemperature</code><br>
            Set comfort target temperature for HKn.</li>
        <li><code>HKn_Soll_Temp_eco_aktiv activate,deactivate</code><br>
            Activate/deactivate eco temperature for HKn.</li>
        <li><code>HKn_Soll_Temp_normal targetTemperature</code><br>
            Sets the normal target temperature for HKn, where <code>targetTemperature</code> is an
            integer between 3 and 37.</li>
        <li><code>HKn_Soll_Temp_reduziert targetTemperature</code><br>
            Sets the reduced target temperature for HKn, where <code>targetTemperature</code> is an
            integer between 3 and 37.</li>
        <li><code>HKn_Name name</code><br>
            Sets the name of the circuit for HKn.</li>      
        <li><code>WW_einmaliges_Aufladen activate,deactivate</code><br>
            Activate or deactivate one-time charge for hot water.</li>
        <li><code>WW_Zirkulationspumpe_Zeitplan schedule</code><br>
            Sets the schedule in JSON format for the hot water circulation pump.</li>
        <li><code>WW_Zeitplan schedule</code> <br>
            Sets the schedule in JSON format for hot water.</li>
        <li><code>WW_Solltemperatur targetTemperature</code><br>
            <code>targetTemperature</code> is an integer between 10 and 60.<br>
            Sets hot water temperature to <code>targetTemperature</code>.</li>    
        <li><code>Urlaub_Start_Zeit start</code><br>
            Set holiday start time.<br>
            <code>start</code> has to look like this: <code>2019-02-02</code>.</li>
        <li><code>Urlaub_Ende_Zeit end</code><br>
            Set holiday end time.<br>
            <code>end</code> has to look like this: <code>2019-02-16</code>.</li>
        <li><code>Urlaub_stop</code> <br>
            Remove holiday start and end time.</li>
    </ul>
    </ul>
    <br>

    <a name="vitoconnectget"></a>
    <b>Get</b><br>
    <ul>
        Nothing to get here. 
    </ul>
    <br>
    
<a name="vitoconnect-attr"></a>
<b>Attributes</b>
<ul>
    <code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code>
    <br><br>
    See <a href="http://fhem.de/commandref.html#attr">commandref#attr</a> for more info about the <code>attr</code> command.
    <br><br>
    Attributes:
    <ul>
        <a id="vitoconnect-attr-disable"></a>
        <li><i>disable</i>:<br>         
            Stop communication with the Viessmann server.
        </li>
        <a id="vitoconnect-attr-verbose"></a>
        <li><i>verbose</i>:<br>         
            Set the verbosity level.
        </li>           
        <a id="vitoconnect-attr-vitoconnect_raw_readings"></a>
        <li><i>vitoconnect_raw_readings</i>:<br>         
            Create readings with plain JSON names like <code>heating.circuits.0.heating.curve.slope</code> instead of German identifiers (old mapping), mapping attribute, or translation attribute.<br>
            When using raw readings, setters will be created dynamically matching the raw readings (new).<br>
            This is activated by default now as this setting ensures you get everything as dynamically as possible from the API.<br>
            You can use <code>stateFormat</code> or <code>userReadings</code> to display your important readings with a readable name.<br>
            If <code>vitoconnect_raw_readings</code> is set, no mapping will be used. Setting this to "svn" forces the module to use a compability mode for the reading names.
            <br>
            <b>Note: Using the old (Roger- or svn-) mappings is no longer recommended, they may be removed later!</b>
        </li>
        <a id="vitoconnect-attr-vitoconnect_disable_raw_readings"></a>
        <li><i>vitoconnect_disable_raw_readings</i>:<br>         
            This setting will disable the additional generation of raw readings.<br>
            This means you will only see the readings that are explicitly mapped in your chosen mapping.<br>
            This setting will not be active if you also choose <code>vitoconnect_raw_readings = 1</code>.
        </li>
        <a id="vitoconnect-attr-vitoconnect_gw_readings"></a>
        <li><i>vitoconnect_gw_readings</i>:<br>         
            Create readings from the gateway, including information if you have more than one gateway.
        </li>
        <a id="vitoconnect-attr-vitoconnect_actions_active"></a>
        <li><i>vitoconnect_actions_active</i>:<br>
            Create readings for actions, e.g., <code>heating.circuits.0.heating.curve.setCurve.setURI</code>.
        </li>
        <a id="vitoconnect-attr-vitoconnect_mappings"></a>
        <li><i>vitoconnect_mappings</i>:<br>
            Define your own mapping of key-value pairs instead of using the built-in ones. The format has to be:<br>
            <code>mapping<br>
            {  'device.serial.value' => 'device_serial',<br>
                'heating.boiler.sensors.temperature.main.status' => 'status',<br>
                'heating.boiler.sensors.temperature.main.value' => 'haupt_temperatur'}</code><br>
            Mapping will be preferred over the old mapping.
        </li>
        <li><i>confFile</i>:<br>
            Option for Client Devices to rename readings und set commands. Provide a file (name) with JSON-encoded  key-value-pairs. keys should be the names of the readings in the "Server"-Device, values are the respective renamed representants in the client device.
            So you may use e.g. the mappings by Roger (8. November, https://forum.fhem.de/index.php?msg=1292441) or the so called SVN mappings.<br>
        </li>
        <a id="vitoconnect-attr-vitoconnect_serial"></a>
        <li><i>vitoconnect_serial</i>:<br>
            This handling will now take place during the initialization of the FHEM device.<br>
            You will be notified that you have to execute <code>set &lt;name&gt; selectDevice &lt;serial&gt;</code>.<br>
            The possible serials will be prefilled.<br>
            You do not need to set this attribute manually.<br>
            Defines the serial of the Viessmann device to be used.<br>
            If there is only one Viessmann device, you do not have to care about it.<br>
        </li>
        <a id="vitoconnect-attr-vitoconnect_installationID"></a>
        <li><i>vitoconnect_installationID</i>:<br>
            This handling will now take place during the initialization of the FHEM device.<br>
            You will be notified that you have to execute <code>set &lt;name&gt; selectDevice &lt;serial&gt;</code>.<br>
            The possible serials will be prefilled.<br>
            You do not need to set this attribute manually.<br>
            Defines the installationID of the Viessmann device to be used.<br>
            If there is only one Viessmann device, you do not have to care about it.<br>
        </li>
        <a id="vitoconnect-attr-vitoconnect_timeout"></a>
        <li><i>vitoconnect_timeout</i>:<br>
            Sets a timeout for the API call.
        </li>
        <a id="vitoconnect-attr-vitoconnect_device"></a>
        <li><i>vitoconnect_device</i>:<br>
            You can define the device 0 (default) or 1. I cannot test this because I have only one device.
        </li>
    </ul>
</ul>

=end html
=begin html_DE

<a id="vitoconnect"></a>
<h3>vitoconnect</h3>
<ul>
    <i>vitoconnect</i> implementiert ein Gerät für die Viessmann API
    <a href="https://www.viessmann.de/de/viessmann-apps/vitoconnect.html">Vitoconnect100</a> oder E3 One Base,
    basierend auf der Untersuchung von
    <a href="https://github.com/thetrueavatar/Viessmann-Api">thetrueavatar</a><br>
    
    Es werden Benutzername und Passwort des ViCare App-Kontos benötigt.<br>
    Zusätzlich auch eine Client-ID, siehe set apiKey.<br>
     
    Weitere Details sind im <a href="https://wiki.fhem.de/wiki/Vitoconnect">FHEM Wiki (deutsch)</a> zu finden.<br><br>
     
    Für die Nutzung werden die folgenden Bibliotheken benötigt:
    <ul>
    <li>Path::Tiny</li>
    <li>JSON</li>
    <li>JSON::XS</li>
    <li>DateTime</li>
    </ul>   
         
    Die Bibliotheken können mit dem Befehl <code>sudo apt install libtypes-path-tiny-perl libjson-perl libdatetime-perl</code> installiert werden oder über cpan. Andernfalls tritt eine Fehlermeldung "cannot load module vitoconnect" auf.
     
    <br><br>
    <a id="vitoconnect-define"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; vitoconnect &lt;user&gt; &lt;password&gt; &lt;interval&gt;</code><br>
        Die Argumente können auch als benannte Liste übergeben werden, z.B.
        <code>define &lt;name&gt; vitoconnect &lt;user=your_API_user&gt; &lt;password=your_password&gt; &lt;apiKey=yourAPIkey&gt; &lt;interval=60&gt;</code><br>
        Werden Passwort bzw. apiKey angegeben, werden diese - analog zu den set-Kommandos 
        weggespeichert und werden aus der Definition entfernt.
        <br>
        Wenn nicht anders angegeben, werden 300 Sekonden als Intervall angenommen.
        <br><br>
        Beispiel:<br>
        <code>define vitoconnect vitoconnect user@mail.xx password=somesecretthing apiKey=someothersecret 60</code><br>
        Wenn nicht über die Definition vorgegeben, können apiKey und Passwort auch später gesetzt werden:<br>
        <code>set vitoconnect password correctPassword</code>
        <code>set vitoconnect apiKey Client-ID</code>
        <br><br>
    </ul>
    <br>
    
    <a id="vitoconnect-set"></a>
    <b>Set</b><br>
    <ul>
        <a id="vitoconnect-set-update"></a>
        <li><code>update</code><br>
            Liest sofort die aktuellen Werte aus.</li>
        <a id="vitoconnect-set-selectDevice"></a>
        <li><code>selectDevice</code><br>
            Wird benötigt, wenn mehr als ein Viessmann Gateway/Device vorhanden ist. Ein Viessmann Gerät muss für jedes FHEM Gerät ausgewählt werden.<br>
            Der Set-Befehl muss ausgeführt werden, nachdem die Viessmann Geräte im Gerätestatus vorgefüllt sind.<br>
            Bei Auswahl eines Viessmann Geräts und Ausführung des Set-Befehls werden die Attribute vitoconnect_serial und vitoconnect_installationId gefüllt.<br>
            Bei nur einem Viessmann Gerät erfolgt dies automatisch.<br>
            Es wird empfohlen, die Änderungen nach der Initialisierung oder dem Set zu speichern.
        </li>
        <a id="vitoconnect-set-clearReadings"></a>
        <li><code>clearReadings</code><br>
            Löscht sofort alle Werte.</li>
        <a id="vitoconnect-set-clearMappedErrors"></a>
        <li><code>clearMappedErrors</code><br>
            Löscht sofort alle gemappten Fehler Werte.</li> 
        <a id="vitoconnect-set-password"></a>
        <li><code>password passwd</code><br>
            Speichert das Passwort im Schlüsselbund.</li>
        <a id="vitoconnect-set-logResponseOnce"></a>
        <li><code>logResponseOnce</code><br>
            Speichert die JSON-Antwort des Viessmann-Servers in den Dateien entities.json, gw.json und actions.json im FHEM-Log-Verzeichnis.
            Wenn mehrere Gateways vorhanden sind, wird die Seriennummer des Gateways an die Dateinamen angehängt.</li>
        <a id="vitoconnect-set-apiKey"></a>
        <li><code>apiKey</code><br>
            Ein API-Schlüssel muss unter https://developer.viessmann-climatesolutions.com/ erstellt werden.
            Dazu ein Konto anlegen, einen neuen Client hinzufügen (Google reCAPTCHA deaktivieren, Redirect URI = http://localhost:4200/).
            Die Client-ID muss als apiKey hier eingefügt werden.</li>
        <li><code>Die Setter für das Gerät hängen von der gewählten Mappingmethode ab, die durch die Attribute vitoconnect_raw_readings oder vitoconnect_mapping_roger gesteuert wird.</code><br>
            Neue Setter werden verwendet, wenn vitoconnect_raw_readings = 1 gesetzt ist.
            Standardmäßig wird das statische Mapping der alten SVN-Version verwendet.
            Die folgenden Setter sind verfügbar:
        </li>
        <li><code>HKn_Heizkurve_Niveau shift</code><br>
            Setzt die Verschiebung der Heizkurve für HKn.</li>
        <li><code>HKn_Heizkurve_Steigung slope</code><br>
            Setzt die Steigung der Heizkurve für HKn.</li>
        <li><code>HKn_Urlaub_Start_Zeit start</code><br>
            Setzt die Urlaubsstartzeit für HKn.<br>
            Start muss im Format: 2019-02-02 angegeben werden.</li>
        <li><code>HKn_Urlaub_Ende_Zeit end</code><br>
            Setzt die Urlaubsendzeit für HKn.<br>
            Ende muss im Format: 2019-02-16 angegeben werden.</li>
        <li><code>HKn_Urlaub_stop</code><br>
            Entfernt die Urlaubsstart- und Endzeit für HKn.</li>
        <li><code>HKn_Zeitsteuerung_Heizung schedule</code><br>
            Setzt den Heizplan für HKn im JSON-Format.<br>
            Beispiel: {"mon":[],"tue":[],"wed":[],"thu":[],"fri":[],"sat":[],"sun":[]} für keinen Betrieb und {"mon":[{"mode":"on","start":"00:00","end":"24:00","position":0}],...} für 24/7 Betrieb.</li>
        <li><code>HKn_Betriebsart heating,standby</code><br>
            Setzt den Betriebsmodus für HKn auf heizen oder standby.</li>
        <li><code>WW_Betriebsart balanced,off</code><br>
            Setzt den Betriebsmodus für Warmwasser auf ausgeglichen oder aus.</li>
        <li><code>HKn_Soll_Temp_comfort_aktiv activate,deactivate</code><br>
            Aktiviert/deaktiviert die Komforttemperatur für HKn.</li>
        <li><code>HKn_Soll_Temp_comfort targetTemperature</code><br>
            Setzt die Komfortzieltemperatur für HKn.</li>
        <li><code>HKn_Soll_Temp_eco_aktiv activate,deactivate</code><br>
            Aktiviert/deaktiviert die Ökotemperatur für HKn.</li>
        <li><code>HKn_Soll_Temp_normal targetTemperature</code><br>
            Setzt die normale Zieltemperatur für HKn (zwischen 3 und 37 Grad Celsius).</li>
        <li><code>HKn_Soll_Temp_reduziert targetTemperature</code><br>
            Setzt die reduzierte Zieltemperatur für HKn (zwischen 3 und 37 Grad Celsius).</li>
        <li><code>HKn_Name name</code><br>
            Setzt den Namen des Kreislaufs für HKn.</li>      
        <li><code>WW_einmaliges_Aufladen activate,deactivate</code><br>
            Aktiviert oder deaktiviert einmaliges Aufladen für Warmwasser.</li>
        <li><code>WW_Zirkulationspumpe_Zeitplan schedule</code><br>
            Setzt den Zeitplan im JSON-Format für die Warmwasserzirkulationspumpe.</li>
        <li><code>WW_Zeitplan schedule</code><br>
            Setzt den Zeitplan im JSON-Format für Warmwasser.</li>
        <li><code>WW_Solltemperatur targetTemperature</code><br>
            Setzt die Warmwassertemperatur (zwischen 10 und 60 Grad Celsius) auf targetTemperature.</li>    
        <li><code>Urlaub_Start_Zeit start</code><br>
            Setzt die Urlaubsstartzeit.<br>
            Start muss im Format: 2019-02-02 angegeben werden.</li>
        <li><code>Urlaub_Ende_Zeit end</code><br>
            Setzt die Urlaubsendzeit.<br>
            Ende muss im Format: 2019-02-16 angegeben werden.</li>
        <li><code>Urlaub_stop</code><br>
            Entfernt die Urlaubsstart- und Endzeit.</li>
    </ul>
</ul>
<br>
    <a name="vitoconnectget"></a>
      <b>Get</b><br>
        <ul>
            Keine Daten zum Abrufen verfügbar.
        </ul>
<br>

<a name="vitoconnect-attr"></a>
<b>Attributes</b>
<ul>
    <code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code>
    <br><br>
    Weitere Informationen zum attr-Befehl sind in der <a href="http://fhem.de/commandref.html#attr">commandref#attr</a> zu finden.
    <br><br>
    Attribute:
    <ul>
        <a id="vitoconnect-attr-disable"></a>
        <li><i>disable</i>:<br>         
            Stoppt die Kommunikation mit dem Viessmann-Server.
        </li>
        <a id="vitoconnect-attr-verbose"></a>
        <li><i>verbose</i>:<br>         
            Setzt das Verbositätslevel.
        </li>
        <a id="vitoconnect-attr-vitoconnect_raw_readings"></a>
        <li><i>vitoconnect_raw_readings</i>:<br>         
            Erstellt Readings mit einfachen JSON-Namen wie 'heating.circuits.0.heating.curve.slope' anstelle von deutschen Bezeichnern (altes Mapping), Mapping-Attributen oder Übersetzungen.<br>
            Wenn raw Readings verwendet werden, werden die Setter dynamisch erstellt, die den raw Readings entsprechen.<br>
            Diese Einstellung entspricht nunmehr dem default und wird empfohlen, um die Daten so dynamisch wie möglich von der API zu erhalten.<br>
            stateFormat oder userReadings können verwendet werden, um wichtige Readings mit einem lesbaren Namen anzuzeigen.<br>
            Wenn vitoconnect_raw_readings nicht bzw. auf "1" gesetzt ist, wird kein Mapping verwendet. Die Einstellung "svn" bewirkt einen Kompabilitätsmodus.
            <br>
            <b>Beachte: Das Verwenden der alten (Roger- bzw. svn-) Mappings ist nicht empfohlen und wird ggf. künftig nicht mehr unterstützt!</b>
        </li>
        <a id="vitoconnect-attr-vitoconnect_disable_raw_readings"></a>
        <li><i>vitoconnect_disable_raw_readings</i>:<br>
            Deaktiviert die zusätzliche Generierung von raw Readings.<br>
            Es werden nur die Messwerte angezeigt, die im gewählten Mapping explizit zugeordnet sind.<br>
            Diese Einstellung wird nicht aktiv, wenn vitoconnect_raw_readings = 1 gesetzt ist.
        </li>
        <a id="vitoconnect-attr-vitoconnect_gw_readings"></a>
        <li><i>vitoconnect_gw_readings</i>:<br>         
            Erstellt ein Reading vom Gateway, einschließlich Informationen, wenn mehrere Gateways vorhanden sind.
        </li>
        <a id="vitoconnect-attr-vitoconnect_actions_active"></a>
        <li><i>vitoconnect_actions_active</i>:<br>
            Erstellt Readings für Aktionen, z.B. 'heating.circuits.0.heating.curve.setCurve.setURI'.
        </li>
        <a id="vitoconnect-attr-vitoconnect_mappings"></a>
        <li><i>vitoconnect_mappings</i>:<br>
            Definiert eigene Zuordnungen von Schlüssel-Wert-Paaren anstelle der eingebauten Zuordnungen. Das Format muss wie folgt sein:<br>
            mapping<br>
            {  'device.serial.value' => 'device_serial',<br>
                'heating.boiler.sensors.temperature.main.status' => 'status',<br>
                'heating.boiler.sensors.temperature.main.value' => 'haupt_temperatur'}<br>
            Die eigene Zuordnung hat Vorrang vor der alten Zuordnung.
        </li>
        <a id="vitoconnect-attr-confFile"></a>
        <li><i>confFile</i>:<br>
            Ermöglicht für Client-Devices die Umbenennung von Readings und set-Befehlen. Die File muss JSON-encodierte key-value-Paare enthalten, jeweils mit den im Server-Device vorhandenen Reading-Namen als keys und dem gewünschten "mapping"-Namen als value.
            Ermöglicht z.B. die Verwendung von Mappings von Roger vom 8. November (https://forum.fhem.de/index.php?msg=1292441) bzw. der SVN-Zuordnung.<br>
        </li>
        <a id="vitoconnect-attr-vitoconnect_serial"></a>
        <li><i>vitoconnect_serial</i>:<br>
            Dieses Attribut wird bei der Initialisierung des FHEM-Geräts gesetzt.<br>
            Der Befehl <code>set <name> selectDevice <serial></code> muss ausgeführt werden, wenn mehrere Seriennummern verfügbar sind.<br>
            Dieses Attribut muss nicht manuell gesetzt werden, wenn nur ein Viessmann Gerät vorhanden ist.
        </li>
        <a id="vitoconnect-attr-vitoconnect_installationID"></a>
        <li><i>vitoconnect_installationID</i>:<br>
            Dieses Attribut wird bei der Initialisierung des FHEM-Geräts gesetzt.<br>
            Der Befehl <code>set <name> selectDevice <serial></code> muss ausgeführt werden, wenn mehrere Seriennummern verfügbar sind.<br>
            Dieses Attribut muss nicht manuell gesetzt werden, wenn nur ein Viessmann Gerät vorhanden ist.
        </li>
        <a id="vitoconnect-attr-vitoconnect_timeout"></a>
        <li><i>vitoconnect_timeout</i>:<br>
            Setzt ein Timeout für den API-Aufruf.
        </li>
        <a id="vitoconnect-attr-vitoconnect_device"></a>
        <li><i>vitoconnect_device</i>:<br>
            Es kann zwischen den Geräten 0 (Standard) oder 1 gewählt werden. Diese Funktion konnte nicht getestet werden, da nur ein Gerät verfügbar ist.
        </li>
        <a id="vitoconnect-attr-weekprofile"></a>
        <li>weekprofile<br>    
        Siehe <a href="#weekprofile-attr-weekprofile">weekprofile-Attribut bei weekprofile</a>        
        </li>
    </ul>
</ul>

=end html_DE

=for :application/json;q=META.json 98_vitoconnect.pm
{
  "abstract": "Using the viessmann API to read and set data",
  "x_lang": {
    "de": {
      "abstract": "Benutzt die Viessmann API zum lesen und setzen von daten"
    }
  },
  "keywords": [
    "inverter",
    "photovoltaik",
    "electricity",
    "heating",
    "burner",
    "heatpump",
    "gas",
    "oil"
  ],
  "version": "v1.1.1",
  "release_status": "stable",
  "author": [
    "Stefan Runge <stefanru@gmx.de>"
  ],
  "x_fhem_maintainer": [
    "Stefanru"
  ],
  "x_fhem_maintainer_github": [
    "stefanru1"
  ],
  "prereqs": {
    "runtime": {
      "requires": {
        "FHEM": 5.00918799,
        "perl": 5.014,
        "POSIX": 0,
        "GPUtils": 0,
        "Encode": 0,
        "Blocking": 0,
        "Color": 0,
        "utf8": 0,
        "HttpUtils": 0,
        "JSON": 4.020,
        "FHEM::SynoModules::SMUtils": 1.0270,
        "Time::HiRes": 0,
        "MIME::Base64": 0,
        "Math::Trig": 0,
        "List::Util": 0,
        "Storable": 0
      },
      "recommends": {
        "FHEM::Meta": 0,
        "FHEM::Utility::CTZ": 1.00,
        "DateTime": 0,
        "DateTime::Format::Strptime": 0,
        "AI::DecisionTree": 0,
        "Data::Dumper": 0
      },
      "suggests": {
      }
    }
  },
  "resources": {
    "x_wiki": {
      "web": "https://wiki.fhem.de/wiki/Vitoconnect",
      "title": "vitoconnect"
    },
    "repository": {
      "x_dev": {
        "type": "svn",
        "url": "https://svn.fhem.de/trac/browser/trunk/fhem/FHEM/",
        "web": "https://svn.fhem.de/trac/browser/trunk/fhem/FHEM/98_vitoconnect.pm",
        "x_branch": "dev",
        "x_filepath": "fhem/contrib/",
        "x_raw": "https://svn.fhem.de/trac/browser/trunk/fhem/FHEM/98_vitoconnect.pm"
      }
    }
  }
}
=end :application/json;q=META.json

=cut
