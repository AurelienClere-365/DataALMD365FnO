function Invoke-DataALMD365FnO {    
    
    try
    {

        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Write-Output "Username launching the Powershell : " $identity

        #PARAMS part - you could also pass through by edtiting this script as arguments
        $UserName = ""
        $Password = ""
        $ClientId = ""
        $ProjectId = ""
        $LcsApiUri = "https://lcsapi.lcs.dynamics.com"
        $ServerInstance = ""

        $stopwatch =  [system.diagnostics.stopwatch]::StartNew()
        
        #Connect to LCS and set it. No MFA Account (dedicated service account - should have access to LCS - AppReg needed for LCS - could be stored to an Azure Key Vault)
        Write-Output "Connect to LCS..."
        Get-D365LcsApiToken -Username $UserName -Password $Password -ClientId $ClientId -LcsApiUri $LcsApiUri | Set-D365LcsApiConfig
        Set-D365LcsApiConfig -ClientId $ClientId -ProjectId $ProjectId
        Write-Output "LCS Connection is OK."
        
        #We retrieve only the latest backup made - could be also possible to pass it through as external parameter or via a filter
        Write-Output "Retrieve the last backup on LCS"
        $Backup = Get-D365LcsDatabaseBackups -Latest
        #We will store in a TEMP folder that you have in DevBox already
        $BackupPath = "C:\Temp\"
        $BackupPath += $Backup.FileName
        #Invoke AzCopy to automatically download it
        Invoke-D365AzCopyTransfer -SourceUri $Backup.FileLocation -DestinationUri $BackupPath -Force
        Write-Output "Backup downloaded to " + $BackupPath

        #Part of the Restore SQL
        #1st we shutdown all AX Services (AOS etc...)
        Write-Output "Stop all AX Services"
        Stop-D365Environment -All
        Write-Output "Waiting 60 seconds, just to make sure that all services are really stopped..."
        Start-Sleep -Seconds 60 #Just to make sure...
        #2nd we erase the previous AxDB - I would suggest anyhow to always activate automatic backup in DevBox if needed ;)
        #Replace by the name of your machine for ServerInstance
        Write-Output "Deleting the previous AxDB..."
        Invoke-SqlCmd -ServerInstance $ServerInstance -Query "BEGIN ALTER DATABASE [AxDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [AxDB]; END;" -Verbose

        #3rd we restore the backup on it 
        Write-Output "Launching the SQL Restore"
        $fileExe = "C:\SqlPackage\sqlpackage.exe"
        & $fileExe /a:import /sf:$BackupPath /tsn:localhost /tdn:AxDB /p:CommandTimeout=1200

        #4th SYNC DB + reactivate all AX Services (AOS etc...)
        Write-Output "Launching SYNC DB"
        Invoke-D365DBSync
        Write-Output "Starting all AX Services"
        Start-D365Environment -All   
        Write-Output "Waiting 60 seconds, just to make sure that all services are really started..."
        Start-Sleep -Seconds 60
        
        #After import we could erase it (the .bacpac) - if you like you can move it elsewhere to archive it.
        Write-Output "Erase the backup downloaded"
        Remove-Item -Path $BackupPath -Force

        $stopwatch.Stop()
        $elapsed = $stopwatch.ElapsedMilliseconds
        $stopwatch.Reset()
        Write-Output $elapsed "Milliseconds in total for the whole operation"
        Write-Output "All OK - Finished"
        
    }
    catch
    {
        Write-Output "Something threw an exception"
    
    }

}

Invoke-DataALMD365FnO > C:\Log_DataALMD365FnO.txt

