#load assemblies
[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SmoExtended") | Out-Null
$ErrorActionPreference = "Inquire"

#Restore Automation Module
#Mike Fal (http://www.mikefal.net)
#Provided under the Creative Commons Attribution Non-Commercial License (http://creativecommons.org/licenses/by-nc/3.0/)
#This module is provided as is, with no guarantees expressed or implied.  Please use the script with
#the appropriate level of caution. 

function Get-RestoreObject{
<#
.SYNOPSIS
Internal function used by New-Restore.
.DESCRIPTION
Internal funciton, returns SMO restore object for processing.
#>
 Param($db,
	$backupfile
    ,$StopAt) 

$rs = new-object("Microsoft.SqlServer.Management.Smo.Restore")
$rs.Devices.AddDevice($backupfile.FullName, "File")
$rs.Database=$db
$rs.NoRecovery=$true
$rs.Action="Database"

if($StopAt){
    $result=0
    if([datetime]::TryParse($StopAt,[ref]$result)){
        $rs.ToPointInTime = $StopAt
    }
    else{
        $rs.StopAtMarkName = $StopAt
    }
}

return $rs
}#Get-RestoreObject

function Get-Header{
<#
.SYNOPSIS
Internal function used by New-Restore.
.DESCRIPTION
Internal funciton, returns SMO backup header for processing.
#>
Param($rs,$srv)

$dt = $restore.ReadBackupHeader($srv)
return $dt.Rows[0]
}#Get-Header

function New-Restore{
<#
.SYNOPSIS
Builds Database Restore script, coordinating Full, Diff, and Log backups.
.DESCRIPTION
Generates a database restore .sql script for restoring a database.  This script can be executed by the function
or simply generate the script for fine-tuning for manual execution.

Script acquires files based on extension:
        bak = Full
        dff = Differential
        trn = Transaction log

Mike Fal (http://www.mikefal.net)

.EXAMPLE
    New-Restore -dir "C:\database_backups" -server "localhost"
    New-Restore -dir "C:\database_backups" -server "localhost" -newdata "X:\MSSQL\data\" -newlog "Y:\MSSQL\logs\"

.PARAMETER dir
    Target directory Where-Object backup files reside (REQUIRED) 
.PARAMETER server
    Target server restore used by SMO to build restore script.  Should be server you want to restore to. (REQUIRED) 
.PARAMETER database 
    Database name to restore. If blank, database name from the backup will be used.
.PARAMETER outputdir
    Output directory for script.  If empty, user's My Documents will be used.
.PARAMETER newdata
    New location of database data files. If not specified, restore will assume default location of the data files.
.PARAMETER newlog
    New location of database log files. If not specified, restore will assume default location of the log files.
.PARAMETER Execute
    Switch parameter.  If true, restore will be executed after script is generated.
.PARAMETER NoRecovery
    Switch parameter.  If true, script will not fully recover database.
.PARAMETER Recurse
    Switch parameter.  If true, script will recurse through all subdirectories for all files of the appropriate extension.
    NOTE:  Currently the file gather will not filter on the restoring database.  Make sure all backup files within the
    subdirectories belong to only one database.

#>

    param([parameter(Mandatory=$true)][string] $dir
    ,[string] $server = "localhost"
    ,[string] $database
    ,[string] $outputdir = ([Environment]::GetFolderPath("MyDocuments"))
    ,[string] $newdata
    ,[string] $newlog
    ,[string] $StopAt
    ,[string] $Owner
    ,[Switch] $Execute
    ,[Switch] $NoRecovery
    ,[Switch] $Recurse)

    $sqlout = @()
    $smosrv = New-Object ('Microsoft.SqlServer.Management.Smo.Server') $server

	if($recurse){
		$full = Get-ChildItem $dir -recurse | Where-Object {$_.name -like "*.bak"} | Sort-Object LastWriteTime -desc | Select-Object -first 1
		$diff = Get-ChildItem $dir -recurse | Where-Object {$_.name -like "*.dff"} | sort-object LastWriteTime -desc | select-object -first 1
		$trns = Get-ChildItem $dir -recurse | Where-Object {$_.name -like "*.trn"} | sort-object LastWriteTime
	}
	else{
		$full = Get-ChildItem $dir | Where-Object {$_.name -like "*.bak"} | Sort-Object LastWriteTime -desc | Select-Object -first 1
		$diff = Get-ChildItem $dir | Where-Object {$_.name -like "*.dff"} | sort-object LastWriteTime -desc | select-object -first 1
		$trns = Get-ChildItem $dir | Where-Object {$_.name -like "*.trn"} | sort-object LastWriteTime
	}

    #initialize and process full backup
    $outputfile = Join-Path -Path $outputdir -ChildPath "restore_$database.sql"
    $restore = Get-RestoreObject $database $full
    $hfull = Get-Header $restore $smosrv
    if($database.Length -eq 0)
    {
	    $database = $hfull.DatabaseName
	    $restore.Database=$database
    }

    $LSNCheck = $hfull.CheckpointLSN
    $files = $restore.ReadFileList($smosrv)
    foreach($file in $files){
	    $pfile = $file.PhysicalName
	    if($newdata.Length -gt 0 -and $file.Type -eq "D"){
		    $pfile=$newdata + $pfile.Substring($pfile.LastIndexOf("\"))
	    }
	
	    if($newdata.Length -gt 0 -and $file.Type -eq "L"){
		    $pfile=$newlog + $pfile.Substring($pfile.LastIndexOf("\"))
	    }
	
	    $newfile = New-Object("Microsoft.SqlServer.Management.Smo.RelocateFile") ($file.LogicalName,$pfile)
	    $restore.RelocateFiles.Add($newfile) | out-null
    }

    $sqlout += "/****************************************************"
    $sqlout += "Restore Database Script Generated $(Get-Date)"
    $sqlout += "Database: "+$database
    $sqlout += "****************************************************/"
    $sqlout += "--FULL RESTORE"
    If($Owner){$sqlout += "EXECUTE AS LOGIN = '$Owner';"}
    $sqlout += $restore.Script($smosrv)

    #process differential backups
    if($diff -ne $null){
	    $restore = Get-RestoreObject $database $diff
	    $hdiff = Get-Header $restore $smosrv

	    if($hdiff.DatabaseBackupLSN -eq $LSNCheck){
		    $sqlout += "--DIFF RESTORE"
		    $sqlout += $restore.Script($smosrv)
		    $LSNCheck = $hdiff.LastLSN
	    }
	    else{
		    $LSNCheck = $hfull.LastLSN
	    }
    }

    #process transaction log backups
    if($trns -ne $null){
	    $sqlout += "--TRN LOG RESTORE"

	    foreach ($trn in $trns){
		    $restore = Get-RestoreObject $database $trn $StopAt
		    $htrn = Get-Header $restore $smosrv
		    if($htrn.FirstLSN -le $LSNCheck -and $htrn.LastLSN -ge $LSNCheck){
			    $sqlout += $restore.Script($smosrv)
			    $LSNCheck = $htrn.LastLSN
		    }
	    }
    }

    #Write final recovery line if necessary
    if(!($NoRecovery)){
	    $sqlout += "`r`n"
	    $sqlout += "--COMPLETE RESTORE/ONLINE DB"
	    $sqlout += "RESTORE DATABASE "+$database + " WITH RECOVERY"
    }

    #output script file
    $sqlout | Out-File $outputfile

    #If called, execute script
    if($Execute){
	    sqlcmd -S "$server" -E -i $outputfile
    }

    Return Get-ChildItem $outputfile

} #New-Restore

function Sync-DBUsers{
<#
.SYNOPSIS
Synchronizes orphaned users with logins.  Returns a list of users that have no corresponding login to sync to.
.DESCRIPTION
Repairs orphaned logins for newly restored databases.  It will compare login names to unmatched SIDs and execute
ALTER USER commands to correct the relationship.  Any users that can not be matched to a login will be listed
as the output.

Mike Fal (http://www.mikefal.net)

.EXAMPLE
    Sync-DBUsers -server "localhost" -database "tpcc"

.PARAMETER server
    Server Where-Object the database resides that is being synchronized.
.PARAMETER database
    Database that has users that needs to be synchronized.

#>
	param([parameter(Mandatory=$true)][string] $server
	,[parameter(Mandatory=$true)][string] $database)

    $smosrv=new-object ('Microsoft.SqlServer.Management.Smo.Server') $server

	$sql = "select d.name " + `
	"from sys.database_principals d " + `
	"join sys.server_principals s on d.name = s.name " + `
	"left join sys.server_principals s2 on d.sid = s2.sid " + `
	"Where-Object d.principal_id > 4 and d.type in ('S','U','G') and s2.sid is null"

	$orphans = $smosrv.Databases[$database].ExecuteWithResults($sql).Tables[0]

	foreach($user in $orphans){
		[string] $sql = "ALTER USER ["+$user.name+"] WITH LOGIN=["+$user.name+"]"
		Invoke-SQLCmd -ServerInstance $server -Database $database -Query $sql
	}
	$sql = "select d.name " + `
	"from sys.database_principals d " + `
	"left join sys.server_principals s2 on d.sid = s2.sid " + `
	"Where-Object d.principal_id > 4 and d.type in ('S','U','G') and s2.sid is null"
	
	$orphans = $smosrv.Databases[$database].ExecuteWithResults($sql).Tables[0]
	
	if($orphans -ne $null){
		Write-Output $orphans
	}
}#Sync-DBUsers

function Get-DBCCCheckDB{
<#
.SYNOPSIS
Executes simple DBCC CHECKDB agasints a target database, providing output of the execution.
.DESCRIPTION
Executes a DBCC CHECKDB WITH PHYSICAL_ONLY, TABLERESULTS against a target database.  Output
is a datatable of the check output.  If the -Full parameter is passed, the command will run a
full DBCC check.

Mike Fal (http://www.mikefal.net)

.EXAMPLE
    Sync-DBUsers -server "localhost" -database "tpcc"

.PARAMETER server
    Server Where-Object the database resides that is being checked.
.PARAMETER database
    Database that has users that needs to be checked.
.PARAMETER Full
    Switch parameter.  If true, a full DBCC check is done against the target database.
#>
	param([parameter(Mandatory=$true)][string] $server
	,[parameter(Mandatory=$true)][string] $database
    ,[Switch] $Full)

    $smosrv=new-object ('Microsoft.SqlServer.Management.Smo.Server') $server

    if($Full){$sql="DBCC CHECKDB($database) WITH TABLERESULTS"}
    else{$sql="DBCC CHECKDB($database) WITH PHYSICAL_ONLY,TABLERESULTS"}

	$results = $smosrv.Databases["tempdb"].ExecuteWithResults($sql).Tables[0]
	
	Write-Output $results
}#Get-DBCCCheckDB

function Copy-Logins{
<#
.SYNOPSIS
   Copies logins from source server to target server.

.DESCRIPTION
   Scripts logins out from a source server using the SMO and 
   copies them to the target.  It uses the .Script() method 
   and also applies all the roles.

.PARAMETER source
   REQUIRED.  Source server that logins are gathered from.

.PARAMETER target
   REQUIRED.  Target server that logins are created on.

.EXAMPLE
   Copy-Logins -target remoteserver -target localhost
#>
[cmdletbinding()]
    param([parameter(Mandatory=$true)][string] $source
        ,[parameter(Mandatory=$true)][string] $target
        )
    #create SMO objects
    $smosource = new-object ('Microsoft.SqlServer.Management.Smo.Server') $source
    $smotarget = new-object ('Microsoft.SqlServer.Management.Smo.Server') $target 	
    
    #set scripting objects
    $so = new-object microsoft.sqlserver.management.smo.scriptingoptions
    $so.LoginSid = $true

    #get logins and loop
    $logins = $smosource.logins
	foreach($login in $logins){
        $lscript = $login.Script($so) | Where-Object {$_ -notlike "ALTER LOGIN*DISABLE"}
        $lscript = $lscript -join " "

        #If SQL Login sort password from pash, replace random password
        if($login.LoginType -eq "SqlLogin"){
            
            $sql = "SELECT convert(varbinary(256),password_hash) as hashedpass FROM sys.sql_logins Where-Object name='"+$login.name+"'"
            $hashedpass = ($smosource.databases['tempdb'].ExecuteWithResults($sql)).Tables.hashedpass
            $passtring = Convert-SQLHashToString $hashedpass
            $rndpw = $lscript.Substring($lscript.IndexOf("PASSWORD"),$lscript.IndexOf(", SID")-$lscript.IndexOf("PASSWORD"))

            $lscript = $lscript.Replace($rndpw,"PASSWORD = $passtring hashed")
        }

        if(!($smotarget.logins.name.contains($login.name))){
            $smotarget.Databases["tempdb"].ExecuteNonQuery($lscript)
            $outmsg="Login " + $login.name + " created."
        }
        else{            
            $outmsg="Login " + $login.name + " skipped."
        }
        Write-Verbose $outmsg
	}
}#Copy-Logins

function Convert-SQLHashToString{
    param([parameter(Mandatory=$true)] $binhash)

    $outstring = "0x"
    $binhash | ForEach-Object {$outstring += ("{0:X}" -f $_).PadLeft(2, "0")}

    return $outstring
}#Convert-SQLHashToString