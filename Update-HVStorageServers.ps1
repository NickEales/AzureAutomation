Param(
	[Parameter(Mandatory=$true)][string]$VMMServerName,
	[Parameter(Mandatory=$true)][string]$AutomationCredential="AutomationUser"
	)
	write-output "executing on $($ENV:Computername)"	
	#Check for required features and modules
	if(-not (get-WindowsFeature -name RSAT-Clustering-PowerShell).installed){
		write-output "Please run 'install-windowsfeature -name RSAT-Clustering-PowerShell'"
		throw "Cluster powershell Feature not installed"
	}else{write-verbose "Cluster PowerShell Module found"}
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
	
	$ServersNeedingUpdate = $VMMManagedComputers | where {$_.ComplianceStatus.Status.Count -eq 0 -and $_.ComplianceStatus.OverallComplianceState -ne "Compliant"}
	write-output "$(@($ServersNeedingUpdate).Count) Server(s) needing an update"
	$HostClusters = Get-SCVMHostCluster -vmmserver $vmmserver
	 
	Foreach($cluster in $HostClusters){
		Foreach($FS in ($Cluster.RegisteredStorageFileShares.StorageFileServer | where {$_.FileServerType -eq "WindowsNonClustered"})){
			if(@($ServersNeedingUpdate.name) -contains $FS.name){
				write-output "Patching $($FS.name)"
				$managedComputer = Get-SCVMMManagedComputer -ComputerName $FS.name -VMMServer $VMMServer
				Start-SCUpdateRemediation -VMMManagedComputer $managedComputer -SuspendReboot -StartNow -VMMServer $VMMServer
			}
		}
	}

	$VMMManagedComputers = Get-SCVMMManagedComputer -VMMServer $VMMServer 
	$serversPendingReboot = $VMMManagedComputers | where {$_.ComplianceStatus.Status -eq 3}
	write-output "$(@($ServersPendingReboot).Count) Server(s) pending reboot"

	Foreach($cluster in $HostClusters){
		$ClusterStopNeeded = $false
		$FSToRemediate = @()
		Foreach($FS in ($Cluster.RegisteredStorageFileShares.StorageFileServer | where {$_.FileServerType -eq "WindowsNonClustered"})){
			if(@($serversPendingReboot.name) -contains $FS.name){
				#Storage server is pending a reboot 
				write-verbose "Adding storage server requiring reboot: $($FS.name)"
				$ClusterStopNeeded=$true
				$FSToRemediate += @($FS.name)
			}
		}
		if($ClusterStopNeeded){
			write-output "stopping cluster: $($cluster.name)"#, using $($adminaccount.username) on $($cluster.nodes[0].name)"

			stop-cluster -cluster $cluster.name -confirm:$false -force 

			if((test-connection -computername $cluster.name -quiet)){
				throw "cluster didn't stop as expected"
			}
			
			foreach($FS in $FStoremediate){
				write-verbose "restarting storage server $FS" 
				write-output "restarting storage server $FS"
				restart-computer -computername $FS -wait
			}

			write-output "restarts completed, restarting cluster: $($cluster.name)"
			start-cluster -cluster $cluster.nodes[0].name 

			write-output "sleeping while cluster starts: $($cluster.name)"
			start-sleep -seconds 30
			
			if(-not (test-connection -computername $cluster.name -quiet)){
				write-error "cluster didn't start as expected"
			}

			write-output "refreshing state of computers in VMM"
			$VMMServer = Get-SCVMMServer -ComputerName $VMMServerName -Credential $AdminAccount
			foreach($FS in $FStoremediate){
				Get-SCVMMManagedComputer $FS -VMMServer $VMMServer | Start-SCComplianceScan -RunAsynchronously | select Name,StatusString
			}	
			Get-SCVMHostCluster -name $cluster -VMMServer $VMMServer | out-null
		}
	}