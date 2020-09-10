  <#
    .SYNOPSIS 
      Export VMware Horizon dedicated desktops configuration
	.DESCRIPTION
	  Use this script to export configuration from VMware Horizon to output folder. This script is part of the migration framework developed by Citrix Systems Inc.
	  This exported configuration can be used by Import-CVADS script.
	.PARAMETER Server
	 Specify IP address or hostname of VMware Connection Server. To use current machine, use 'localhost' value (default)
	.PARAMETER DoNotOpen
	 Output folder should not be opened automatically once export operation is finished. 
  #>

Param (
    [String]$Server = "localhost"
)

#DISCLAIMER:
#This software application is provided to you “AS IS” with no representations, warranties or conditions of any kind. You may use and distribute it at your own risk. 
#CITRIX DISCLAIMS ALL WARRANTIES WHATSOEVER, EXPRESS, IMPLIED, WRITTEN, ORAL OR STATUTORY, INCLUDING WITHOUT LIMITATION WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NONINFRINGEMENT. 
#Without limiting the generality of the foregoing, you acknowledge and agree that (a) the software application may exhibit errors, design flaws or other problems, possibly resulting in loss of data or damage to property; 
#(b) it may not be possible to make the software application fully functional; and (c) Citrix may, without notice or liability to you, cease to make available the current version and/or any future versions of the software 
#application. In no event should the code be used to support of ultra-hazardous activities, including but not limited to life support or blasting activities. 
#NEITHER CITRIX NOR ITS AFFILIATES OR AGENTS WILL BE LIABLE, UNDER BREACH OF CONTRACT OR ANY OTHER THEORY OF LIABILITY, FOR ANY DAMAGES WHATSOEVER ARISING FROM USE OF THE SOFTWARE APPLICATION, 
#INCLUDING WITHOUT LIMITATION DIRECT, SPECIAL, INCIDENTAL, PUNITIVE, CONSEQUENTIAL OR OTHER DAMAGES, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGES. 
#You agree to indemnify and defend Citrix against any and all claims arising from your use, modification or distribution of the code.

Write-Host "--------------------------------------------"
Write-Host "| VMware Horizon Migration Script - Export |"
Write-Host "--------------------------------------------"
Write-Host

$ErrorActionPreference = "Stop";

[System.DirectoryServices.DirectoryEntry]$PublishingDir = [ADSI]("LDAP://$($Server):389/OU=Applications,dc=vdi,dc=vmware,dc=int");
[System.DirectoryServices.DirectoryEntry]$PoolsDir = [ADSI]("LDAP://$($Server):389/OU=Server Groups,dc=vdi,dc=vmware,dc=int");
[System.DirectoryServices.DirectoryEntry]$DesktopsDir = [ADSI]("LDAP://$($Server):389/OU=Servers,dc=vdi,dc=vmware,dc=int");

# Test if connected successfully
If ($Null -eq $PublishingDir.distinguishedName -or $Null -eq $PoolsDir.distinguishedName -or $Null -eq $DesktopsDir.distinguishedName) {
    Throw "Failed to connect to LDAP database using LDAP://$($Server):389"
}

# Create $MainPath variable that defines folder where the script is located. If code is executed manually (copy & paste to PowerShell window), current directory is being used
Write-Host "Detecting current path"
If ($MyInvocation.MyCommand.Path -is [Object]) {
    [string]$MainPath = $(Split-Path -Parent $MyInvocation.MyCommand.Path);
} Else {
    [string]$MainPath = $(Get-Location).Path;
}


[String]$OutputPath = Join-Path $MainPath "HorizonExport\$([DateTime]::Now.ToString('yyyy_MM_dd-hh_mm'))";
MkDir $OutputPath | Out-Null;

Write-Host "Starting session log"
Try {
    Start-Transcript -Append -Path "$OutputPath\Export.log" | Out-Null
} Catch {Write-Host "An exception happened when starting transcription: $_" -ForegroundColor Red }

"This file is used to identify that this folder contains exported configuration" > "$OutputPath\Migration.check"

# VMware Horizon does not provide a simple value that would identify resource pool as a dedicated type, instead it is using multiple values for resource pool type
# To find all dedicated pools, we find any desktops with assigned users and create an array of their parent pools
Write-Host "Loading resource pools with dedicated desktops: " -NoNewline;
[Array]$PersistentPools = $DesktopsDir.Children | Select-Object * | Where-Object {$_.member -is [object]} | Select-Object -Unique -ExpandProperty pae-MemberDNOf
Write-Host $PersistentPools.Count;
Write-Host

# Export all information
ForEach ($m_Pool in $PersistentPools) {
    Write-Host
    Write-Host "Processing pool: " -NoNewline;
    Write-Host $m_Pool -ForegroundColor Yellow;

    # Retrieve pool object reference based on DN
    Write-Host "Retrieving pool object reference"
    $m_PoolObject = $PoolsDir.Children | Where-Object {$_.distinguishedName -eq $m_Pool};

    Write-Host "Preparing export folders"
    [String]$ExportFolder = "$OutputPath\Desktops\$($m_PoolObject.cn)"

    # Create subfolder based on pool ID
    MkDir "$ExportFolder\Pool" | Out-Null;
    MkDir "$ExportFolder\VirtualMachines" | Out-Null;
    MkDir "$ExportFolder\Entitlements" | Out-Null;
    
    Write-Host "Exporting pool configuration"
    Export-Clixml -InputObject $m_PoolObject -Path "$ExportFolder\Pool\PoolConfiguration.xml";

    Write-Host "Exporting desktops: " -NoNewline
    ForEach ($m_Desktop in $DesktopsDir.Children | Where-Object {$_.'pae-MemberDNOf' -eq $m_PoolObject.distinguishedName}) {
        Write-Host "." -NoNewline
        Export-Clixml -InputObject $m_Desktop -Path "$ExportFolder\VirtualMachines\$($m_Desktop.'pae-DisplayName').xml";
    }
    Write-Host 

    Write-Host "Retrieving publishing configuration"
    $m_PublishingObject = $PublishingDir.Children | Where-Object {$_.'pae-Servers' -eq $m_PoolObject.distinguishedName};
    
    Write-Host "Exporting entitlements: " -NoNewline
    ForEach ($m_Entitlement in $m_PublishingObject.member) {
        Write-Host "." -NoNewline
        # Extract SID from distinguished name
        [String]$m_SID = $m_Entitlement.Split("=,,")[1];
        Export-Clixml -InputObject $m_SID -Path "$ExportFolder\Entitlements\$($m_SID).xml";
    }
    Write-Host
    
}

Write-Host
Write-Host "VMware Horizon export has been finished"
Write-Host "Configuration was exported to folder $ExportFolder"

Try {
    Stop-Transcript | Out-Null
} Catch { Write-Host "An exception happened when stopping transcription: $_" -ForegroundColor Red }
