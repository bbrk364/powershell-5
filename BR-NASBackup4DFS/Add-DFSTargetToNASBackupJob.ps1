﻿<# 
   .SYNOPSIS
   Getting Shares behind Reparse Points and add them to a NAS Backup Job
   .DESCRIPTION
   This script finds the shares behind an DFS namespace structure and adds it to VBR NAS Backup Job. You can configure
   the folder scan depth 
   .PARAMETER DfsRoot
   With this parameter you specify the UNC path to scan e.g. "\\fileserver\dfs".
   .PARAMETER VBRJobName
   This is the existing Job where the detected shares should be added.
   .PARAMETER ShareCredential
   Enter the Credentials which should be used. They must be from VBR credentials manager.
   .PARAMETER CacheRepository
   Enter the Repository which should be used for Cache.
   .PARAMETER ScanDepth
   How deep in the subfolder structure the script should scan for reparse points?
   .PARAMETER LogFile
   You can set your own path for log file from this script. Default filename is "C:\ProgramData\dfsresolver4nasbackup.log"

   .Example
   .\Add-DFSTargetToNASBackupJob.ps1 -DfsRoot "\\homelab\dfs" -VBRJobName "NAS DFS Test" -ShareCredential "HOMELAB\Administrator" -CacheRepository "Default Backup Repository" -ScanDepth 2

   .Example
   .\Add-DFSTargetToNASBackupJob.ps1 -DfsRoot "\\homelab\dfs" -VBRJobName "NAS DFS Test" -ShareCredential "HOMELAB\Administrator" -CacheRepository "Default Backup Repository" -ScanDepth 2 -VolumeProcessingMode VSSSnapshot
   .Notes 
   Version:        1.0
   Author:         Marco Horstmann (marco.horstmann@veeam.com)
   Creation Date:  22 October 2019
   Purpose/Change: Reworked documentation and commenting of code.
   
   .LINK https://github.com/veeamhub/powershell
   .LINK https://horstmann.in
 #> 
[CmdletBinding(DefaultParameterSetName="__AllParameterSets")]
Param(

   [Parameter(Mandatory=$True)]
   [string]$DfsRoot,

   [ValidateSet(“Direct”,”StorageSnapshot”,”VSSSnapshot”)]
   [Parameter(Mandatory=$False)]
   [string]$VolumeProcessingMode="Direct",

   [Parameter(Mandatory=$True)]
   [string]$VBRJobName,

   [Parameter(Mandatory=$True)]
   [string]$ShareCredential,

   [Parameter(Mandatory=$True)]
   [string]$CacheRepository,

<#
   [Parameter(Mandatory=$False)]
   [string]$FileServerName,
#>

   [Parameter(Mandatory=$False)]
   [string]$LogFile="C:\ProgramData\dfsresolver4nasbackup.log",

   [Parameter(Mandatory=$True)]
   [int]$ScanDepth
)


PROCESS {

    # This function is used to log status to console and also the given logfilename.
    # Usage: Write-Log -Status [Info, Status, Warning, Error] -Info "This is the text which will be logged
    function Write-Log($Info, $Status)
    {
        switch($Status)
        {
            NewLog {Write-Host $Info -ForegroundColor Green  ; $Info | Out-File -FilePath $LogFile}
            Info    {Write-Host $Info -ForegroundColor Green  ; $Info | Out-File -FilePath $LogFile -Append}
            Status  {Write-Host $Info -ForegroundColor Yellow ; $Info | Out-File -FilePath $LogFile -Append}
            Warning {Write-Host $Info -ForegroundColor Yellow ; $Info | Out-File -FilePath $LogFile -Append}
            Error   {Write-Host $Info -ForegroundColor Red -BackgroundColor White; $Info | Out-File -FilePath $LogFile -Append}
            default {Write-Host $Info -ForegroundColor white $Info | Out-File -FilePath $LogFile -Append}
        }
    } #end function 

    # This function will scan a folder for subfolders and if it finds a reparse point it returns the reparsepoints up.
    function Scan-Folder($path, $currentdepth, $maxdepth) {
        #Increment the currentdepth parameter to end nesting of this fuction within itself.
        $currentdepth++
        #create a folderarray which is used locally for each call of this function (works even in function call in a function call)
        $folderarray = @()
        #Gets all folders of the given path  and for each object it checks its attributes for reparse points. If one folder is also a reparse point it will added to the folderarray
        Get-ChildItem -Path $path -Directory | ForEach-Object {
            if($_.Attributes -like "*ReparsePoint*") {
                $folderarray += $_.FullName
                Write-Log "Found Reparse Point $_ ... ADD TO REPARSE POINT LIST" -Status Info
            }
            # If the currentdepth e.g.2. is less or equal to maxdepth e.g. 3 it will make a nested function call for the current folder
            if($currentdepth -le $maxdepth) {
                # Because a reparse Point below Reparse Point in DFS is not possible. If folder is a reparse point
                # we do not need to dive deeper because we will not found anymore in this folder.
                if(!($_.Attributes -like "*ReparsePoint*")) {
                    $folderarray += Scan-Folder -path $_.FullName -currentdepth $currentdepth -maxdepth $maxdepth
                }
            }
        }
        return $folderarray
    }

    # This function will get an array of reparse points and will locate the target paths and return them
    function Get-SourceShare($reparsepoints) {
        $sharearray = @()
        $reparsepoints | ForEach-Object {
            $sharearray  += Get-DfsnFolderTarget $_
        }
        return $sharearray
    }

    # Main Code starts
    #
    Write-Log -Status NewLog -Info "Starting new log file"
  
    # Check if DFS Management Tools are installed
    Write-Log -Status Info -Info "Checking if DFS Management Tools are installed ..."
    if(get-windowsFeature -Name "RSAT-DFS-Mgmt-Con" | Where-Object -Property "InstallState" -EQ "Installed") {
        Write-Log -Status Info -Info "DFS Management Tools are already installed... SKIPPED"
    } else {
        Write-Log -Status Status -Info "DFS Management Tools are not installed... INSTALLING..."
        try {
            Install-WindowsFeature -Name "RSAT-DFS-Mgmt-Con" -Confirm:$false
            Write-Log -Info "DFS Management Tools was installed... DONE" -Status Info
        } catch  {
            Write-Log -Info "$_" -Status Error
            Write-Log -Info "Installing DFS Management Tools... FAILED" -Status Error
            exit 99
        }
    }
    # Check if Veeam Module can be loaded
    Write-Log -Status Info -Info "Trying to load Veeam PS Snapins ..."
    try {
        Add-PSSnapin VeeamPSSnapin
        Write-Log -Info "Veeam PS Snapin loaded" -Status Info
    } catch  {
        Write-Log -Info "$_" -Status Error
        Write-Log -Info "Failed to load Veeam PS Snapin" -Status Error
        exit 99
    }

    # Validate parameters: VBRJobName
    Write-Log -Status Info -Info "Checking VBR Job Name"
    try {
        $nasBackupJob = Get-VBRNASBackupJob -name $VBRJobName
        Write-Log -Info "VBR Job Name ... FOUND" -Status Info
    } catch  {
        Write-Log -Info "$_" -Status Error
        Write-Log -Info "Failed to find job name" -Status Error
        exit 99
    }
    # Validate parameters: ShareCrendential
    Write-Log -Status Info -Info "Checking Share Credentials"
    if($ShareCredential = Get-VBRCredentials -Name $ShareCredential | Select -Last 1) {
        Write-Log -Info "Share Credentials ... FOUND" -Status Info
    } else  {
        Write-Log -Info "Failed to find share credentials" -Status Error
        exit 99
    }

    # Validate parameters: Cache Repository
    Write-Log -Status Info -Info "Checking Share Credentials"
    if(Get-VBRBackupRepository -name $CacheRepository)  {
        Write-Log -Info "Cache Repository ... EXISTS" -Status Info
    } else {
        Write-Log -Info "Cache Repository ... NOT FOUND" -Status Error
        exit 50
    }
    
    # Scan for Reparse Points
    Write-Log -Status Info -Info "Scanning for Reparse Points"
    try {
        $allreparsepoints = Scan-Folder -path $DfsRoot -currentdepth 1 -maxdepth $ScanDepth
        if( $allreparsepoints.Count -eq 0 ) {
            Write-Log -Info "Reparse Points ... NOT FOUND" -Status Error
            exit 
        } else {
            Write-Log -Info "Reparse Points ... FOUND" -Status Info
        }
    } catch  {
        Write-Log -Info "$_" -Status Error
        Write-Log -Info "Failed to find reparse points" -Status Error
        exit 99
    }

    
    # Getting all Shares
    Write-Log -Status Info -Info "Resolving Reparse Points to Shares"
    try {
        $allshares = Get-SourceShare -reparsepoints $allreparsepoints
        Write-Log -Info "Shares ... FOUND" -Status Info
    } catch  {
        Write-Log -Info "$_" -Status Error
        Write-Log -Info "Failed to find shares" -Status Error
        exit 99
    }
    
  
    # Creates an empty VBRNASBackupJobObject where we need to add the 
    $VBRNASBackupJobObject = @()
    # For each detected share to this 
    $allshares | ForEach-Object {
       <#
        # ToDo: Add a filter for $allshares like only for shares from one system
        if($FileServerName) {
            $allshares | ForEach-Object {
                if($_.TargetPath -ilike "\\$FileServerName\*") {
                    Write-Host $_.TargetPath
                } else {
                Write-Host "Nicht so"
                }
            }
        }
        #>
        $currentPath = $_.TargetPath
        # Gets the info for NAS Server Name
        $VBRNASServer = Get-VBRNASServer | Where-Object { $_.Path -eq $currentPath }
        #Check if share is already added to VBR. If not create share in VBR, else just skip
        if(!(Get-VBRNASServer -Name $_.TargetPath)) {
            Add-VBRNASSMBServer -Path $_.TargetPath -AccessCredentials $ShareCredential -ProcessingMode $VolumeProcessingMode -ProxyMode Automatic -CacheRepository $CacheRepository
            Write-Log -Info "Adding $currentPath to VBR... DONE" -Status Info
        } else  {
           Write-Log -Info "Share $currentPath is already added... SKIPPING" -Status Info
        }
        # Add this share to the list of NASBackupJobObjects
        # Here is the right point to add e.g. exclusion and inclusion masks
        $VBRNASBackupJobObject += New-VBRNASBackupJobObject -Server $VBRNASServer -Path $currentPath
    }

    # Updating existing job with this NASBackupJobObjects 
    Set-VBRNASBackupJob -Job $nasBackupJob -BackupObject $VBRNASBackupJobObject
    
       
} # END PROCESS