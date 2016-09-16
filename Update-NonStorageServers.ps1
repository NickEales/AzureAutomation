param(
	[Parameter(Mandatory=$true)][string]$VMMServerName,
	[Parameter(Mandatory=$true)][string]$AutomationCredential="AutomationUser"
)

	write-output "executing on $($ENV:Computername)"	
	#Check for required features and modules
	if((get-module -list | where name -match virtualmachinemanager).count -eq 0){
		Throw "Virtual Machine Manager powershell module not installed on $($ENV:Computername)"
	}else{write-verbose "Virtual Machine Manager powershell module found"}
	
	#get credential to use with SCVMM
	$AdminAccount = Get-AutomationPSCredential -Name $AutomationCredential
	if($AdminAccount -eq $NULL){throw "Unable to get Automation Credential $AutomationCredential"}	
	$VMMServer = Get-SCVMMServer -ComputerName $VMMServerName -Credential $AdminAccount
	if($VMMServer -eq $NULL){Throw "Unable to Connect to VMMServer $VMMServerName using Automation Credential $($AutomationCredential.username)"}
	write-output "Connected to VMM server $($VMMServer.name)"

	$VMMManagedComputers = Get-SCVMMManagedComputer -VMMServer $VMMServer 
	if($VMMManagedComputers -eq $null){Throw "no VMMManagedComputers"}
	write-output "$($VMMManagedComputers.Count) managed computers found" 
	
	$ServersNeedingUpdate = $VMMManagedComputers | where {($_.ComplianceStatus.Status.Count -eq 0 -and $_.ComplianceStatus.OverallComplianceState -ne "Compliant") -or $_.ComplianceStatus.Status -eq 3}
	write-output "$(@($ServersNeedingUpdate).Count) Server(s) needing an update"
	write-output $($ServersNeedingUpdate.ComplianceStatus | select name,overallcompliancestate,status)

	$PatchGroups=@{
		Clusters=@()
		StandaloneHosts=@()
		Infrastructure=@()
		UpdateServer=@()
		Library=@()
		VMMServerRole=@()
		NonHAVMMHosts=@()
	}

	$HostClusters = Get-SCVMHostCluster -vmmserver $vmmserver
	$VMMHostServer = (get-scvirtualmachine | where {$_.computername -eq $vmmserver.name -and $_.isHighlyAvailable -eq $false}).vmhost.name
    $NonHAStorageServers=(@(@(get-scvmhost), @(get-scvmhostcluster))).RegisteredStorageFileShares.StorageFileServer | where {$_.FileServerType -eq "WindowsNonClustered"} | select -expand name | select -unique
	write-output "Grouping servers"
	foreach($ServerToPatch in $ServersNeedingUpdate){
		#write-output "finding the group for $($servertoPatch.name)"
		if($HostClusters.Nodes.ManagedComputer -contains $serverToPatch){
			$Cluster = $hostclusters | where {$_.nodes.managedcomputers -contains $ServerToPatch}
			if($PatchGroups.Clusters -notcontains $cluster){
				$PatchGroups.Clusters += @($cluster)
			}
		}elseif($NonHAStorageServers -contains $serverToPatch.Name){
            #do nothing with this server - it is handled in seperate runbook
		}elseif($ServerToPatch.Role -match "Host" -and $serverToPatch.Name -ne $VMMHostServer){
			write-output "StandaloneHosts += $($serverToPatch.Name)"
			$PatchGroups.StandaloneHosts += @($ServerToPatch)
		}elseIf($ServerToPatch.Role -match "Infrastructure"){
			write-output "Infrastructure += $($serverToPatch.Name)"
			$PatchGroups.Infrastructure += @($ServerToPatch)
		}elseIf($ServerToPatch.Role -match "VMMServerRole"){
			write-output "VMMServerRole += $($serverToPatch.Name)"
			$PatchGroups.VMMServerRole += @($ServerToPatch)
		}elseIf($ServerToPatch.Role -match "UpdateServer"){
			write-output "UpdateServer += $($serverToPatch.Name)"
			$PatchGroups.UpdateServer += @($ServerToPatch)
		}elseIf($ServerToPatch.Role -match "Library"){
			write-output "Library += $($serverToPatch.Name)"
			$PatchGroups.Library += @($ServerToPatch)
		}elseIf($serverToPatch.Name -eq $VMMHostServer){
			write-output "NonHAVMMHosts += $($serverToPatch.Name)"
			$PatchGroups.NonHAVMMHosts += @($ServerToPatch)
		}else{
			write-error "Unknown Managed Computer Type ($($ServerToPatch):$($ServerToPatch.Role))"
		}
	}

	write-output "Grouping Completed. Starting remediation / reboots as necessary"

	foreach($Cluster in $PatchGroups.Clusters){
		write-output "starting remediation for cluster $($cluster.Name)"
		$result = Start-SCUpdateRemediation -VMHostCluster $Cluster -UseLiveMigration -StartNow -VMMServer $VMMServer
		$result | select name,compliancestate | write-output
	}

	Foreach($Group in @("StandaloneHosts","Infrastructure","Library","UpdateServer","VMMServerRole","NonHAVMMHosts")){
		foreach($ServerToPatch in $PatchGroups.$Group){
			if($serverToPatch.OverallComplianceState -eq "Compliant" -and $serverToPatch.ComplianceStatus.Status -eq 3){
				write-output "restarting $group server: $($ServerToPatch.Name)"
				restart-computer -computername $servertopatch.name -wait	
			}else{
				write-output "starting remediation for $group server: $($ServerToPatch.Name)"
				if($group -match "NonHAVMMHosts"){
					#non-HAVMM hosts task needs to be run asynchronously as the command will not return correctly. 
					$result = Start-SCUpdateRemediation -VMMManagedComputer $ServerToPatch -StartNow -VMMServer $VMMServer -runasynchronously
					write-output "sleeping while we wait for VMM host remediation"
					#arbitrary 10 minutes.
					start-sleep -seconds 600
				}else{
					$result = Start-SCUpdateRemediation -VMMManagedComputer $ServerToPatch -StartNow -VMMServer $VMMServer
				}
				if($group -match "VMM"){
					write-output "Sleeping before trying to reconnect to VMM"
					start-sleep -seconds 120
					while(-not $(test-connection -ComputerName $VMMServerName -quiet)){
						start-sleep -seconds 60
					} 
					start-sleep -seconds 120
					$VMMServer = Get-SCVMMServer -ComputerName $VMMServerName -Credential $AdminAccount
					if($VMMServer -eq $NULL){Throw "Unable to Connect to VMMServer $VMMServerName using Automation Credential $($AutomationCredential.username)"}
				}
				$result | select name,compliancestate | write-output
			}
		}
	}
