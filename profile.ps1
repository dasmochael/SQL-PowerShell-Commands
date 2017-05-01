﻿#load SMO library
[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null

function Get-FreeSpace{
<#
.SYNOPSIS
Uses WMI to get capacity and freespace for all disks/mounts on a host.

.DESCRIPTION
Uses WMI Win32_Volume to query logical disks and provide drive size and usage for all
logical disks and mountpoints.  If no parameter is given, localhost is used.  Otherwise
the host name should be passed.

Mike Fal (http://www.mikefal.net) 2012-10-10

.PARAMETER
String
    host - Name of machine information is being queried from, defaults to localhost

.EXAMPLE
    Get-FreeSpace "CCX-SQL-PRD-01"
#>

    param([string] $hostname = ($env:COMPUTERNAME))

	gwmi win32_volume -computername $hostname  | where {$_.drivetype -eq 3} | Sort-Object name `
	 | ft name,@{l="Size(GB)";e={($_.capacity/1gb).ToString("F2")}},@{l="Free Space(GB)";e={($_.freespace/1gb).ToString("F2")}},@{l="% Free";e={(($_.Freespace/$_.Capacity)*100).ToString("F2")}}

}

function Test-SQLConnection{
    param([parameter(mandatory=$true)][string] $InstanceName)

    $smosrv = new-object ('Microsoft.SqlServer.Management.Smo.Server') $InstanceName
    $return = New-Object –TypeName PSObject –Prop @{'InstanceName'=$InstanceName;'StartupTime'=$null}
    try{
        $check=$smosrv.Databases['tempdb'].ExecuteWithResults('SELECT @@SERVERNAME')
        $return.InstanceName = $smosrv.Name
        $return.StartupTime = $smosrv.Databases['tempdb'].CreateDate
    }
    catch{
        #do nothing on the catch
    }

    return $return
}

function Test-SQLAGRole{
    param([parameter(mandatory=$true,ValueFromPipeline=$true)][string] $ComputerName)


    If(Test-SQLConnection -ComputerName $computerName){
        $smosrv = new-object ('Microsoft.SqlServer.Management.Smo.Server') $ComputerName
        if($smosrv.AvailabilityGroups[0].PrimaryReplicaServerName -eq $smosrv.ComputerNamePhysicalNetBIOS){return "Primary"}
        else{"Secondary"}
    }
    else{
        return "Unreachable"
    }
}