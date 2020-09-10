<#
.SYNOPSIS 
  Import VMware Horizon configuration to Citrix Virtual Apps and Desktops service. Configuration has to be exported using Export-Horizon.ps1 script. 
.DESCRIPTION
  Import VMware Horizon configuration to Citrix Virtual Apps and Desktops service. Configuration has to be exported using Export-Horizon.ps1 script. You can identify this exported configuration by finding a file called "Migration.check".
.PARAMETER Path
 Specify the existing folder with exported VMware Horizon configuration. If not specified, .\HorizonExport folder is used. When this folder contains only single exported configuration, it will be selected automatically.
.PARAMETER OnPrem
 Import script will by default try to connect to Citrix Cloud. If you want to specify traditional on-premises environment as a target, use -onprem parameter (without any arguments)
.PARAMETER HypervisorConnectionName
 Specify the name of the hypervisor connection in Citrix Virtual Apps and Desktops service (in Citrix Studio, under Configuration\Hosting). This parameter is required in order to create a power managed catalog (by default, Unmanaged catalog is created instead). 
 This connection should provide access to all VMs that are being migrated. 
.EXAMPLE
 .\Import-CVADS.ps1
 This command will try to import VMware Horizon configuration in folder .\HorizonExport and automatically import it to Citrix Virtual Apps and Desktops service.
.EXAMPLE
 .\Import-CVADS.ps1 -onprem
 This command will try to import VMware Horizon configuration in folder .\HorizonExport and automatically import it to traditional on-premises Citrix Virtual Apps and Desktops environment.
.EXAMPLE
 .\Export-CVADS.ps1 -Path C:\ExportHorizon -HypervisorConnectionName vCenter01
 This command will migrate VMware Horizon configuration from folder C:\ExportHorizon folder to CVADS. Hypervisor connection vCenter01 will be used for a power management of the machines. Connection name is defined in Citrix Studio under "Configuration \ Hosting".
#>

#DISCLAIMER:
#This software application is provided to you “AS IS” with no representations, warranties or conditions of any kind. You may use and distribute it at your own risk. 
#CITRIX DISCLAIMS ALL WARRANTIES WHATSOEVER, EXPRESS, IMPLIED, WRITTEN, ORAL OR STATUTORY, INCLUDING WITHOUT LIMITATION WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NONINFRINGEMENT. 
#Without limiting the generality of the foregoing, you acknowledge and agree that (a) the software application may exhibit errors, design flaws or other problems, possibly resulting in loss of data or damage to property; 
#(b) it may not be possible to make the software application fully functional; and (c) Citrix may, without notice or liability to you, cease to make available the current version and/or any future versions of the software 
#application. In no event should the code be used to support of ultra-hazardous activities, including but not limited to life support or blasting activities. 
#NEITHER CITRIX NOR ITS AFFILIATES OR AGENTS WILL BE LIABLE, UNDER BREACH OF CONTRACT OR ANY OTHER THEORY OF LIABILITY, FOR ANY DAMAGES WHATSOEVER ARISING FROM USE OF THE SOFTWARE APPLICATION, 
#INCLUDING WITHOUT LIMITATION DIRECT, SPECIAL, INCIDENTAL, PUNITIVE, CONSEQUENTIAL OR OTHER DAMAGES, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGES. 
#You agree to indemnify and defend Citrix against any and all claims arising from your use, modification or distribution of the code.

Param (
	[ValidateScript({Test-Path $_ -PathType "Container"})][String]$Path,
	[String]$HypervisorConnectionName,
	[Switch]$OnPrem
)

Write-Host "--------------------------------------------"
Write-Host "| VMware Horizon Migration Script - Import |"
Write-Host "--------------------------------------------"
Write-Host

$ErrorActionPreference = "Stop";

#Region "Support functions"

Function New-AccessRules ([Citrix.Broker.Admin.SDK.DesktopGroup]$DeliveryGroup, [Array]$Groups) {
	#Region "Access rules"
	
		#TODO - Check if exists
		Write-Host "	Defining if assignment or entitlement is needed: " -NoNewline
		If ($DeliveryGroup.DesktopKind -eq "Private") {
			Write-Host "Desktop Assignment required" -ForegroundColor Green
	        New-BrokerAssignmentPolicyRule -Name "$($DeliveryGroup.Name)" -DesktopGroupUid $DeliveryGroup.Uid -IncludedUserFilterEnabled $false -ErrorAction SilentlyContinue | Out-Null
	    } ElseIf ($DeliveryGroup.DesktopKind -eq "Shared" -and $DeliveryGroup.DeliveryType -ne "AppsOnly") {
			Write-Host "Desktop Entitlement required" -ForegroundColor Green
	        New-BrokerEntitlementPolicyRule -Name "$($DeliveryGroup.Name)" -DesktopGroupUid $DeliveryGroup.Uid -IncludedUserFilterEnabled $false -ErrorAction SilentlyContinue | Out-Null
	    } ElseIf ($DeliveryGroup.DesktopKind -eq "Shared" -and $DeliveryGroup.DeliveryType -eq "AppsOnly") {
			Write-Host "App Entitlement required" -ForegroundColor Green
			New-BrokerAppEntitlementPolicyRule -Name "$($DeliveryGroup.Name)" -DesktopGroupUid $DeliveryGroup.Uid -IncludedUserFilterEnabled $false -ErrorAction SilentlyContinue | Out-Null
		} Else {
			KO -Test "Scenario not covered"
		}
		
		#TODO - Check if exists
		Write-Host "	Creating access policy rule for direct connections: " -NoNewline
		New-BrokerAccessPolicyRule -DesktopGroupUid $DeliveryGroup.Uid -AllowedConnections "NotViaAG" -Name "$($DeliveryGroup.Name)_Direct" -IncludedUserFilterEnabled $true -AllowedProtocols @("HDX","RDP") -AllowRestart $true -IncludedSmartAccessFilterEnabled $true -IncludedUsers $Groups -ErrorAction SilentlyContinue | Out-Null
		OK

		#TODO - Check if exists
		Write-Host "	Creating access policy rule for AG connections: " -NoNewline
		New-BrokerAccessPolicyRule -DesktopGroupUid $DeliveryGroup.Uid -AllowedConnections "ViaAG" -Name "$($DeliveryGroup.Name)_AG" -IncludedUserFilterEnabled $true -AllowedProtocols @("HDX","RDP") -AllowRestart $true -IncludedSmartAccessFilterEnabled $true -IncludedSmartAccessTags @() -IncludedUsers $Groups  -ErrorAction SilentlyContinue | Out-Null
		OK
		#EndRegion
}

Function OK ([string]$Text = "OK") {Write-Host $Text -ForegroundColor Green}

Function KO ([string]$Text = "KO") {Write-Host $Text -ForegroundColor Red}

Function Wait-ManualConfirmation ([String]$Message) {
    While ($True -ne $False) {
        Write-Host $Message -ForegroundColor Yellow;
        [String]$m_Input = Read-Host "Then type 'yes' to continue or 'no' to abort";
        If ($m_Input -eq "yes") {
            Return;
        } ElseIf ($m_Input -eq 'no') {
            Throw "Aborting script";
        } Else {
            Write-Host "Input $m_Input was not recognized, try again? Allowed values are 'yes' or 'no'"
        }
    }
}

#EndRegion

#Region "Preparations"

# Import script supports for CVAD and CVADS environment - for CVADS, SdkProxy module is required
Write-Host "Testing required PowerShell modules for Citrix Cloud: " -NoNewline
If (-not $OnPrem) {
	If ($(Get-Module Citrix.PoshSdkProxy.Commands -ListAvailable) -isnot [System.Management.Automation.PSModuleInfo]) {
		KO; 
		
		Write-Host "Citrix Virtual Apps and Desktops Remote PowerShell SDK is required for Citrix Cloud connection. This script will now abort, you can try it again after you install the required SDK." -ForegroundColor Red
		Wait-ManualConfirmation -Message "Do you want to download the required SDK? You can also download it manually from https://download.apps.cloud.com/CitrixPoshSdk.exe"
		
		Start-Process "https://download.apps.cloud.com/CitrixPoshSdk.exe";

		Throw "CVADS Remote Powershell SDK is not available"
	} Else {
		OK;
		# Establish connection to Citrix Cloud
		If ($(Test-Path Variable:GLOBAL:XDAuthToken) -ne $True) {
			Get-XDAuthentication;
		}
	}
} Else {OK -Text "Not required"}

Write-Host "Testing required PowerShell modules for CVAD: " -NoNewline
If ($(Get-Module Citrix.Broker.Commands -ListAvailable) -isnot [System.Management.Automation.PSModuleInfo]) {
	KO;
	Throw "Required PowerShell module Citrix.Broker.Commands has not been found";
} Else {OK}

Write-Host "Validating input folder: " -NoNewline

# If -path is not configured, try to find if a simple exported folder is available
If ($Path.Length -eq 0) {

	# Create $CurrentFolder variable that defines folder where the script is located. If code is executed manually (copy & paste to PowerShell window), current directory is being used
	If ($MyInvocation.MyCommand.Path -is [Object]) {
		[string]$CurrentFolder = $(Split-Path -Parent $MyInvocation.MyCommand.Path);
	} Else {
		[string]$CurrentFolder = $(Get-Location).Path;
	}

	If (Test-Path "$CurrentFolder\HorizonExport") {
		[Array]$m_ExportedFolders = Get-ChildItem "$CurrentFolder\HorizonExport" | Where-Object {$_.PsIsContainer -eq $True}

		# Make sure that only one subfolder exists
		If ($m_ExportedFolders.Count -ne 1) {KO; Throw "Failed to locate the proper exported configuration. Expected location $CurrentFolder\HorizonExport, found $($m_ExportedFolders.Count) exported configurations here (expected 1). You can use -path argument to specify custom location."};

		If ($(Test-Path "$($m_ExportedFolders[0].Fullname)\Migration.check") -eq $False) {
			KO; Throw "Folder $($m_ExportedFolders[0].Fullname) is invalid export - file Migration.check was not found";
		}

		Wait-ManualConfirmation -Message "Detected export folder $($m_ExportedFolders[0].Fullname). Do you want to import this folder? If not, you can specify custom folder using -path argument"

		$Path = $($m_ExportedFolders[0].Fullname);

	} Else {KO; Throw "Exported configuration was not found in folder $CurrentFolder\HorizonExport. You can use -path argument to specify custom location."}
}

If ($(Test-Path $Path\Migration.check) -eq $false) {
	KO
	Throw "Path you've specified is not a valid exported VMware Horizon configuration"
} Else {OK}

Write-Host "Preparing log file: " -NoNewline
Try {
	Start-Transcript -Force -Append -Path "$Path\Import_$([DateTime]::Now.ToString('yyyy_MM_dd-hh_mm')).log" | Out-Null
	OK;
} Catch {KO; Write-Host "An exception happened when starting transcription: $_" -ForegroundColor Red }

#EndRegion

#Region "Import dedicated desktops"

Write-Host
Write-Host "Dedicated desktops migration" -ForegroundColor Yellow 
Write-Host "Deciding if desktops should be imported: " -NoNewline
If ($(Test-Path $Path\Desktops) -eq $true) {
	OK


	#Region "Power Management configuration"
		
	Write-Host "Detecting if catalog should be power managed: " -NoNewline
	[Boolean]$IsPowerManaged = $False
	If ($HypervisorConnectionName.Length -gt 0) {
		OK

		[Boolean]$IsPowerManaged = $True
			
		# This module needs to be loaded to create XDHyp:\ mapping
		Write-Host "Loading hypervisor module: " -NoNewline;
		If ($(Get-Module Citrix.Host.Commands) -isnot [PSModuleInfo]) {
			Import-Module Citrix.Host.Commands;
		}
		OK

		Write-Host "Validating hypervisor connection: " -NoNewline
		If ($(Test-Path "XDHyp:\Connections\$HypervisorConnectionName") -eq $True) {
			OK
		} Else {
			KO
			Throw "Hypervisor connection with name $HypervisorConnectionName has not been found. Available connections: $(Get-BrokerHypervisorConnection | Select-Object -ExpandProperty Name)"
		}

		[Citrix.Broker.Admin.SDK.HypervisorConnection]$m_HyperConnection = Get-BrokerHypervisorConnection -Name $HypervisorConnectionName;

		Write-Host "Retrieving list of all VMs: " -NoNewline
		[HashTable]$vCenterVMs = @{}
		[Array]$m_vCenterRawVMs = Get-ChildItem XDHyp:\Connections\$HypervisorConnectionName -Recurse | Where-Object {$_.ObjectType -eq "VM"}
		OK -Text $m_vCenterRawVMs.Count
			
		Write-Host "Generating hashtable: " -NoNewline
		ForEach ($m_vCenterVM in $m_vCenterRawVMs) {
			If (-not $vCenterVMs.ContainsKey($m_vCenterVM.Name.ToLower())) {
				$vCenterVMs.Add($m_vCenterVM.Name.ToLower(), $m_vCenterVM)
			}
		}
		OK
			
					
	} Else {KO}
	
	#EndRegion

	Write-Host "Processing all pools"
	ForEach ($m_Pool in Get-ChildItem -Path $Path\Desktops | Where-Object {$_.PsIsContainer -eq $True}) {
		Write-Host
		Write-Host "	Processing pool " -NoNewline
		Write-Host $m_Pool.BaseName -ForegroundColor Yellow
	
		Write-Host "	Importing configuration: " -NoNewline
		$m_PoolConfiguration = Import-Clixml -Path "$($m_Pool.FullName)\Pool\PoolConfiguration.xml"
		OK
	
		# Convert to string from arraylist
		[String]$m_PoolName = $m_PoolConfiguration.name[0];
		[String]$m_PoolDisplayName = $m_PoolConfiguration.'pae-DisplayName'[0];
		[String]$m_PoolType = $m_PoolConfiguration.'pae-ServerPoolType'[0];

		Write-Host "	Retrieving a Catalog: " -NoNewline
		$m_Catalog = Get-BrokerCatalog -Name $m_PoolName -ErrorAction SilentlyContinue
		If ($m_Catalog -is [Object]) {
			OK
		} Else {
			KO
			Write-Host "	Catalog not found, creating new catalog: " -NoNewline
			# PoolType 6 is Remote PC equivalent, not suitable for power management
			If ($IsPowerManaged -and $m_PoolType -ne 6) {
				$m_Catalog = New-BrokerCatalog -AllocationType Static -CatalogKind PowerManaged -Description "Imported from VMware Horizon" -Name $m_PoolName
			} Else {
				$m_Catalog = New-BrokerCatalog -AllocationType Static -CatalogKind Unmanaged -Description "Imported from VMware Horizon" -Name $m_PoolName
			}
			OK
		}
		
		
		Write-Host "	Retrieving a Delivery Group: " -NoNewline
		$m_DeliveryGroup = Get-BrokerDesktopGroup -Name $m_PoolName -ErrorAction SilentlyContinue
		
		if ($m_DeliveryGroup -is [Object]) {
			OK
		} Else {
			KO
			Write-Host "	Delivery Group not found, creating new Delivery Group: " -NoNewline
			$m_DeliveryGroup = New-BrokerDesktopGroup -PublishedName $([System.Text.RegularExpressions.Regex]::Replace($m_PoolDisplayName,"[^0-9a-zA-Z _-]","_")) -DesktopKind Private -Name $m_PoolName
			OK
		}
		
		Write-Host "	Retrieving list of users\groups"
		[Array]$m_UsersToInclude = @()
		ForEach ($m_Entitlement in Get-ChildItem -Path "$($m_Pool.FullName)\Entitlements" -Filter *.xml) {
			$m_EntitlementSID = Import-Clixml -Path $m_Entitlement.FullName
			Write-Host "		$($m_EntitlementSID)" -ForegroundColor Gray
			Try {
				$m_UsersToInclude += New-BrokerUser -SID $m_EntitlementSID
			} Catch {
				KO -Text "			User not found, skipping"
			}
			
		}
		
		New-AccessRules -DeliveryGroup $m_DeliveryGroup -Groups $m_UsersToInclude
		
		Write-Host "	Importing virtual machines"
		:VMProcessing ForEach ($m_VM in Get-ChildItem -Path "$($m_Pool.FullName)\VirtualMachines" -Filter *.xml) {
		
			$m_VMObject = Import-Clixml -Path $m_VM.FullName

			[String]$m_VMDNSName = $m_VMObject.ipHostNumber[0];
			[String]$m_VMShortName = $m_VMDNSName.Split(".")[0];
			[String]$m_VMDisplayName = $m_VMObject.'pae-DisplayName'[0];
			
			
			Write-Host "		$($m_VMDisplayName): " -ForegroundColor Gray -NoNewline
					
			If ($(Get-BrokerMachine -MachineName "*\$m_VMShortName" -ErrorAction SilentlyContinue) -is [Citrix.Broker.Admin.SDK.Machine]) {
				KO -Text "KO - Existing machine detected"
				Continue VMProcessing
			}
			
			# Add machine to catalog
			If ($IsPowerManaged -and $m_VMObject.'pae-VmPath'.Count -gt 0) {
				[String]$m_VMHypervisorName = Split-Path -Path $m_VMObject.'pae-VmPath'[0] -Leaf;
				If ($vCenterVMs.$($m_VMHypervisorName) -isnot [Object]) {
					KO -Text "KO - VM has not been found on hypervisor";
					Continue VMProcessing
				}
				$m_Machine = New-BrokerMachine -CatalogUid $m_Catalog.Uid -MachineName "$m_VMShortName" -HypervisorConnectionUid $m_HyperConnection.Uid -HostedMachineId $($vCenterVMs.$($m_VMHypervisorName)).ID
				OK -Text "OK - Power managed"
			} Else {
				$m_Machine = New-BrokerMachine -CatalogUid $m_Catalog.Uid -MachineName "$m_VMShortName"
				OK -Text "OK - Unmanaged"
			}	

			# Add maching to Delivery Group
			Add-BrokerMachine -InputObject $m_Machine -DesktopGroup $m_DeliveryGroup
			
			# If user is defined, assign user to the desktop
			If ($m_VMObject.member[0].Length -gt 0) {
				Try {
					# Extract SID from string
					[String]$m_UserSID = $m_VMObject.member[0].Split("=,")[1]
					Write-Host " 		-> $($m_UserSID)" -ForegroundColor Gray
					Add-BrokerUser $m_UserSID -PrivateDesktop $m_Machine.MachineName
				} Catch {
					KO -Text "			SID not translated, account probably doesn't exists in Active Directory, skipping"
				}
			} Else {Write-Host}
		}
	}
} Else {KO}

#EndRegion

#Region "Finalize" 

Try {
    Stop-Transcript | Out-Null
} Catch { Write-Host "An exception happened when stopping transcription: $_" -ForegroundColor Red }

#EndRegion
