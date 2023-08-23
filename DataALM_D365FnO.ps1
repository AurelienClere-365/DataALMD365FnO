function Local-FixBacPacModelFile
{
    param(
        [string]$sourceFile, 

        [string]$destinationFile,

        [int]$flushCnt = 500000
    )

# This script can be used to remove AutoDrop properties from the model file of a
# SQL Server 2022 (or equivalient Azure SQL) bacpac backup.
# This enables restoring the bacpac on a SQL server 2019.
# See also https://github.com/d365collaborative/d365fo.tools/issues/747
# Original script by @batetech in https://www.yammer.com/dynamicsaxfeedbackprograms/#/Threads/show?threadId=2382104258371584
# Minor changes by @FH-Inway
# Gist of script: https://gist.github.com/FH-Inway/f485c720b43b72bffaca5fb6c094707e

    if($sourceFile.Equals($destinationFile, [System.StringComparison]::CurrentCultureIgnoreCase))
    {
        throw "Source and destination files must not be the same."
        return;
    }

    $searchForString = '<Property Name="AutoDrop" Value="True" />';
    $replaceWithString = '';

    #using performance suggestions from here: https://learn.microsoft.com/en-us/powershell/scripting/dev-cross-plat/performance/script-authoring-considerations
    # * use List<String> instead of PS Array @()
    # * use StreamReader instead of Get-Content
    $buffer = [System.Collections.Generic.List[string]]::new($flushCnt) #much faster than PS array using +=
    $buffCnt = 0;

    #delete dest file if it already exists.
    if(Test-Path -LiteralPath $destinationFile)
    {
        Remove-Item -LiteralPath $destinationFile -Force;
    }

    try
    {
        $stream = [System.IO.StreamReader]::new($sourceFile)
        $streamEncoding = $stream.CurrentEncoding;
        Write-Verbose "StreamReader.CurrentEncoding: $($streamEncoding.BodyName) $($streamEncoding.CodePage)"

        while ($stream.Peek() -ge 0)
        {
            $line = $stream.ReadLine()
            if(-not [string]::IsNullOrEmpty($line))
            {
                $buffer.Add($line.Replace($searchForString,$replaceWithString));
            }
            else
            {
                $buffer.Add($line);
            }

            $buffCnt++;
            if($buffCnt -ge $flushCnt)
            {
                Write-Verbose "$(Get-Date -Format 'u') Flush buffer"
                $buffer | Add-Content -LiteralPath $destinationFile -Encoding UTF8
                $buffer = [System.Collections.Generic.List[string]]::new($flushCnt);
                $buffCnt = 0;
                Write-Verbose "$(Get-Date -Format 'u') Flush complete"
            }
        }
    }
    finally
    {
        $stream.Dispose()
        Write-Verbose 'Stream disposed'
    }

    #flush anything still remaining in the buffer
    if($buffCnt -gt 0)
    {
        $buffer | Add-Content -LiteralPath $destinationFile -Encoding UTF8
        $buffer = $null;
        $buffCnt = 0;
    }

}

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
        $LcsApiUri = "https://lcsapi.lcs.dynamics.com" #To change if you have different LCS geo-region like lcsapi.eu.lcs.dynamics.com
        $ServerInstance = "" #Local Server instance name

        
        # Will be created by script. Existing files will be overwritten.
        $modelFilePath = "C:\Temp\BacpacModel.xml" 
        $modelFileUpdatedPath = "C:\Temp\UpdatedBacpacModel.xml"

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
        Export-D365BacpacModelFile -Path $BackupPath -OutputPath $modelFilePath -Force
        Local-FixBacPacModelFile -sourceFile $modelFilePath -destinationFile $modelFileUpdatedPath
        Write-Output "Launching the SQL Restore"
        $fileExe = "C:\SqlPackage\sqlpackage.exe"
        & $fileExe /a:import /sf:$BackupPath /tsn:localhost /tdn:AxDB /p:CommandTimeout=1200 /TargetEncryptConnection:False /ModelFilePath:$modelFileUpdatedPath

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

