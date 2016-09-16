#Azure Automation Powershell Runbook to update SCVMM Baselines with current applicable updates from WSUS.
#written by Nick Eales.
#Last Update 16 Sept 2016
Param(
	[Parameter(Mandatory=$true)][String]$VMMServerName,
	[String]$AdminAccount="AutomationUser"
)

Function Update-SingleScvmmBaseline{ 
    Param ( 
        [Parameter(Mandatory=$true,Position=0)] 
        [String] $BaseLineName,
        [Parameter(Mandatory=$true,Position=1)]
        [Microsoft.UpdateServices.Internal.BaseApi.Update[]]$AllUpdates
    ) 
  
    write-output "Starting Baseline '$BaselineName'" -foregroundcolor Green

    $baseline = Get-SCBaseline -Name $BaseLineName 
    if($Baseline -eq $NULL){
        Write-output "Baseline '$BaselineName' not found - adding to VMM with all managed computers in scope"
        Add-Baseline -BaseLineName $BaseLineName
    }
    $BaselineUpdates = $AllUpdates | where UpdateClassificationTitle -eq $baselineName

    write-output "$($baseline.UpdateCount) : Current updates in Baseline '$BaseLineName'"

    write-verbose "$($BaselineUpdates.count) Updates found of classification '$baselineName' that are approved in WSUS and not superseded or expired"

    #Filter list of updates to those not currently in baseline
    $AddedUpdates = $BaselineUpdates | where {$baseline.Updates.updateid -notcontains $_.id.updateid.guid}
    #Convert list to type that we can use for Set-SCBaseline
    $addedUpdateList = get-scupdate | where {$AddedUpdates.id.updateid.guid -contains $_.updateid.GUID}

    write-output "$($addedUpdateList.Count) : New updates to add in to baseline '$BaseLineName'"
    if(($addedUpdateList| measure).count -gt 0){
        Set-SCBaseline -Baseline $baseline -Name $BaseLineName -Description $BaseLineName -AddUpdates $addedUpdateList  | ft ObjectType,name,updatecount -autosize
    }
     
    write-verbose "Scan WSUS for Updates that should not be Checked anymore"  
    $removeUpdateList = $baseline.Updates | Where {$BaselineUpdates.id.updateid.guid -notcontains $_.updateid}

    write-output "$($removeUpdateList.count) : Updates to remove from baseline '$BaseLineName'"
    if(($removeUpdateList | measure).count -gt 0){
        Set-SCBaseline -Baseline $baseline -Name $BaseLineName -Description $BaseLineName -RemoveUpdates $RemoveupdateList  | ft ObjectType,name,updatecount -autosize
    }
} 

Function Get-FilteredListOfUpdates{
    param([Microsoft.UpdateServices.Internal.BaseApi.UpdateServer]$wsus)
    #directly connecting to WSUS for list of update - This gives far more reliable filtering than using SCVMM 

    $AllUpdates=$Wsus.GetUpdates() | 
        where {
            $_.IsSuperseded -eq $False -and 
            $_.IsApproved -eq $true -and 
            $_.isBeta -eq $false -and 
            $_.isdeclined -eq $false -and 
            $_.islatestrevision -eq $true -and 
            $_.publicationstate -ne "Expired" -and 
            $_.title -notmatch "itanium" 
        }

    # Get list of operating systems in use on the computers managed by SCVMM
    # - will use WMI to query some managed computers for OS version. 
    $VMHostOSs=get-scvmhost | Where {$_.operatingSystem -match "(\S+\sServer\s\d+\s\S\d)|(\S+\sServer\s\d+)|(\S+\sServer)"} | %{$matches[0]}
    $VMMManagedComputerOSs = get-scvmmmanagedcomputer | where role -ne Host | select -unique FQDN | where {(Get-WmiObject -class Win32_OperatingSystem -ComputerName $_.FQDN -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).caption -match "(\S+\sServer\s\d+\s\S\d)|(\S+\sServer\s\d+)|(\S+\sServer)"} | %{$matches[0]}
    $OperatingSystems = @($VMHostOSs) + @($VMMManagedComputerOSs) | select -Unique

    write-verbose "Filtering to operating systems: $($OperatingSystems -join ',')"
    $UpdatesToUse = @()
    foreach($os in $OperatingSystems){
        $UpdatesToUse += $allupdates | where {$_.ProductTitles -contains $OS -or $_.ProductTitles -notmatch "^Windows" -or $_.ProductTitles -match "$OS$"}
    }
    write-verbose "$($UpdatesToUse.count) Updates found for included operating systems."

    return($UpdatesToUse)
}

write-output "Running on $($ENV:Computername)"

#Check for required features and modules
if(-not (get-WindowsFeature -name UpdateServices-API).installed){
	write-output "Please run 'install-windowsfeature -name UpdateServices-API' on ''$($ENV:Computername)''"
	throw "WSUS Powershell module not installed"
}else{write-verbose "WSUS PowerShell Module found"}
if((get-module -list | where name -match virtualmachinemanager).count -eq 0){
	Throw "Virtual Machine Manager powershell module not installed on $($ENV:Computername)"
}else{write-verbose "Virtual Machine Manager powershell module found"}

write-output "Getting credential to use"
$AdminCred = Get-AutomationPSCredential -Name $AdminAccount
if($AdminCred -eq $NULL){throw "Unable to get Automation Credential '$AdminAccount'"}	

write-output "Connecting to VMM Server '$VMMServerName' as '$($AdminCred.Username)' (From $adminAccount Credential Asset)"
$VMMServer = Get-SCVMMServer -Computername $VMMServerName -Credential $AdminCred
if($VMMServer -eq $null){Throw "Unable to connect to VMMServer $VMMServerName"}

write-output "Connecting to update server"
$SCUpdateServer = Get-SCUpdateServer -vmmserver $vmmserver
if($SCUpdateServer -eq $NULL){Throw "unable to get WSUS server from VMM Server $($VMMServer.FQDN)"}

Write-output "Synchronizing WSUS Server with VMM server $($VMMServer.FQDN)"  
$SCUpdateServer | Start-SCUpdateServerSynchronization | FL ServerType,UpstreamServerName,Version,Name,SynchronizationType,SynchronizationTimeOfTheDay
$wsus = Get-WSUSServer -name $SCUpdateServer.Name -portnumber $SCUpdateServer.Port
if($wsus -eq $NULL){Throw "unable to connect to WSUS server $($SCUpdateServer.Name):$($SCUpdateServer.Port)"}

Write-output "Getting list of current applicable updates for the operating systems managed by VMM"
$FilteredUpdates = Get-FilteredListOfUpdates -wsus $wsus

@("Security Updates","Critical Updates","Updates","Update Rollups", "Hotfix") | %{Update-SingleScvmmBaseline -BaseLineName $_ -allupdates $FilteredUpdates}
 
write-output "Start Compliance Scan for all Servers"  
Get-SCVMMManagedComputer | Start-SCComplianceScan -RunAsynchronously | select name,overallcompliancestate,statusstring