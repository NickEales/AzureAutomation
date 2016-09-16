Param(
	[String]$VMMServerName = "VMM",
	[String]$AdminAccount="AutomationUser"
)



Function Update-BaseLineUpdates{ 
    Param ( 
	$Wsus,
    [Parameter(Mandatory=$false, 
    ValueFromPipeline=$true, 
    ValueFromPipelineByPropertyName=$true, 
    ValueFromRemainingArguments=$false, 
    Position=0)] 
    [String] 
    $BaseLineName
    ) 
  
    write-output "Starting Baseline '$BaselineName'"

    $baseline = Get-SCBaseline -Name $BaseLineName 
    write-output "$($baseline.UpdateCount) : Current updates in Baseline $BaseLineName"

    write-verbose "Get list of updates from WSUS for this classification" 
    $AllUpdates=$Wsus.GetUpdates() | where UpdateClassificationTitle -eq $baselineName | where {$_.IsSuperseded -eq $False -and $_.IsApproved -eq $true -and $_.isBeta -eq $false -and $_.isdeclined -eq $false -and $_.islatestrevision -eq $true -and $_.publicationstate -ne "Expired" -and $_.title -notmatch "itanium"}

    write-verbose "$($AllUpdates.count) Updates before filtering"
    $OperatingSystems = get-scvmhost | Where {$_.operatingSystem -match "(\S+\sServer\s\d+\s\S\d)|(\S+\sServer\s\d+)|(\S+\sServer)"} | %{$matches[0]}  | select -unique
    write-verbose "Filtering to operating systems: $($OperatingSystems -join ',')"

    $OSUpdates = @()
    foreach($os in $OperatingSystems){
        $OSUpdates += $allupdates | where {$_.ProductTitles -contains $OS -or $_.ProductTitles -notmatch "^Windows" -or $_.ProductTitles -match "$OS$"}
    }
    $AllUpdates = $OSUpdates
    write-verbose "$($allupdates.count) Updates found for included operating systems."

    write-verbose "Filter list of updates to those not currently in baseline"
    $AddedUpdates = $allupdates | where {$baseline.Updates.updateid -notcontains $_.id.updateid.guid}
    $addedUpdateList = get-scupdate | where {$AddedUpdates.id.updateid.guid -contains $_.updateid.GUID}

    write-output "$($addedUpdateList.Count) : New updates to add in $BaselineName"
    if(($addedUpdateList| measure).count -gt 0){
        Set-SCBaseline -Baseline $baseline -Name $BaseLineName -Description $BaseLineName -AddUpdates $addedUpdateList  | ft ObjectType,name,updatecount -autosize
    }
     
    write-verbose "Scan WSUS for Updates that should not be Checked anymore"  
    $removeUpdateList = $baseline.Updates | Where-Object -Property UpdateClassification -EQ -Value $BaseLineName | where {$AllUpdates.id.updateid.guid -notcontains $_.updateid}

    write-output "$($removeUpdateList.count) : Updates to remove from $baselineName"
    if(($removeUpdateList | measure).count -gt 0){
        Set-SCBaseline -Baseline $baseline -Name $BaseLineName -Description $BaseLineName -RemoveUpdates $RemoveupdateList  | ft ObjectType,name,updatecount -autosize
    }
} 

	#Check for required features and modules
	if(-not (get-WindowsFeature -name UpdateServices-API).installed){
		write-output "Please run 'install-windowsfeature -name UpdateServices-API' on ''$($ENV:Computername)''"
		throw "WSUS Powershell module not installed"
	}else{write-verbose "WSUS PowerShell Module found"}
	if((get-module -list | where name -match virtualmachinemanager).count -eq 0){
		Throw "Virtual Machine Manager powershell module not installed on $($ENV:Computername)"
	}else{write-verbose "Virtual Machine Manager powershell module found"}

write-output "Running on $($ENV:Computername)"
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

Update-BaseLineUpdates -wsus $Wsus -baselinename "Security Updates"  
Update-BaseLineUpdates -wsus $Wsus -baselinename "Critical Updates"
Update-BaseLineUpdates -wsus $Wsus -baselinename "Updates"
Update-BaseLineUpdates -wsus $Wsus -baselinename "Update Rollups"
Update-BaseLineUpdates -wsus $Wsus -baselinename "Hotfix"
 
write-output "Start Compliance Scan for all Servers"  
Get-SCVMMManagedComputer | Start-SCComplianceScan -RunAsynchronously | select name,overallcompliancestate,statusstring