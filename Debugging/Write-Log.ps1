<#
.Synopsis
    A function that writes messages onto the console and logs them into a log file if provided. 
.DESCRIPTION
    A function that writes messages onto the console and logs said messages into a provided log file. The function also has custom error handling messages to help
    speed up the 'debugging' aspect of scripting.
.PARAMETER Message
    The output message to be displayed/logged.
.PARAMETER EntryType
    The type of message this may be (e.g., Verbose, Information, Warning, Error, or Debug)
.PARAMETER ErrorInfo
    If the EntryType is set to error, use this parameter to pass the ErrorRecord object (e.g., $_) and the function will log/output a better visual
    as to what the error may be.
.PARAMETER Path
    The path in which the log file resides.
.NOTES
    Author - Zack
.EXAMPLE
    Write-Log "This is an informative message"

    The above outputs the default 'Information' EntryType, which is essentially a 'Write-Output'. 
.EXAMPLE
    try { 
        Get-Process -Name 'Random Name' -ErrorAction Stop
    } catch {
        Write-Log -Message "Could not find process Random Name" -EntryType Error -ErrorInfo $_
    }

    The above code snipplet demonstrates how to use the Error output of said function.
.EXAMPLE
    Write-Log -Message "This is a warning message." -EntryType Warning -Path "C:\Windows\Temp\Logging.csv"

    The above demonstrates how to write a warning message to the console and to log file 'C:\Windows\Temp\Logging.csv'
.INPUTS
    None
.OUTPUTS
    System.String if EntryType 'Information' is used.
.LINK
    Github: https://github.com/thonkerguns/PowerShell
#>
function Write-Log {
    [cmdletbinding()]
    param
    (
        [Parameter(Mandatory,
            Position=0)]
            [ValidateNotNullOrEmpty()]
        [String]$Message,

        [Parameter(Mandatory=$false,
            Position=1)]
            [ValidateNotNullOrEmpty()]
            [ValidateSet('Verbose', 'Information', 'Warning', 'Error', 'Debug')]
        [String]$EntryType = 'Information',

        [parameter(Mandatory=$false,
            Position=2)]
            [ValidateNotNullOrEmpty()]
        [System.Management.Automation.ErrorRecord]$ErrorInfo,

        [parameter(Mandatory=$false,
            Position=3)]
        [string]$Path = '.\Log.csv'
    )

    begin {
        
        # Create the default Hash Table (Ordered is added so the columns will be displayed as they are stored in the table)
        [pscustomobject]$Log = [ordered]@{
            Time = (Get-Date -f g)
            ComputerName = $env:ComputerName
            EntryType = $EntryType
            Message = $Message
        }

        # If the log file doesn't exist, we'll need to populate the first row regardless if there's an error or not
        if (-not (Test-Path -Path $Path)) {
            if ($EntryType -eq "Error" -and $null -ne $ErrorInfo) {
                $Log.Add('ErrorFullyQualifiedErrorID', (($ErrorInfo).FullyQualifiedErrorId))
                $Log.Add('ErrorMessage', (($ErrorInfo).Exception.Message))
                $Log.Add('ErrorCategory', (($ErrorInfo).CategoryInfo.Category))
                $Log.Add('ErrorScriptStackTrace', (($ErrorInfo).ScriptStackTrace))
            } else {
                # File doesn't exist but we don't have an error. Populate columns with an empty row
                $Log.Add('ErrorFullyQualifiedErrorID', '')
                $Log.Add('ErrorMessage', '')
                $Log.Add('ErrorCategory', '')
                $Log.Add('ErrorScriptStackTrace', '')
            }
            
        } else {

            # File exists, only add the error information if necessary
            if ($EntryType -eq 'Error' -and ($null -ne $ErrorInfo)) {
                $Log.Add('ErrorFullyQualifiedErrorID', (($ErrorInfo).FullyQualifiedErrorId))
                $Log.Add('ErrorMessage', (($ErrorInfo).Exception.Message))
                $Log.Add('ErrorCategory', (($ErrorInfo).CategoryInfo.Category))
                $Log.Add('ErrorScriptStackTrace', (($ErrorInfo).ScriptStackTrace))
            }
        }    
    }
    process
    {
        
        # Save data from the hash table into the log file
        # NOTE: If the file is opened with Excel, you will get an error. 
        if ($null -ne $Path -and $Path -ne "") {
            $Log | Export-Csv -Path $Path -Append -NoTypeInformation -Force
        }
        
        # Output to Console depending on the given EntryType
        switch ($EntryType)
        {
            'Verbose'       {Write-Verbose -Message $Message}
            'Information'   {Write-Output $Message}
            'Warning'       {Write-Warning -Message $Message}
            'Debug'         {Write-Debug -Message $Message}
            'Error'         {
                # Output Error information onto the console
                if ($null -ne $ErrorInfo) {
                    Write-Error -Message @"
                    `nScript Stack Trace: $(($ErrorInfo).ScriptStackTrace)
                    `nFully Qualified ErrorID: $($ErrorInfo.FullyQualifiedErrorId)

                    `nError Message: $(($ErrorInfo).Exception.Message)
                    `nError Category: $(($ErrorInfo).CategoryInfo.Category)
                    `n$Message
"@
                } else {
                    # ErrorInfo wasn't provided, just output the provided message.
                    Write-Error -Message $Message
                } 
            }
        }
    }
}
