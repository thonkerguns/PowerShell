<#
.Synopsis
    Invoke-LoadRemoteFunctions will load the provided functions into a given session for execution.
.DESCRIPTION
    Invoke-LoadRemoteFunctions will prepare functions/commands on a remote session for later usage. Instead of copying functions within your Invoke-Command, you can run this command once
    and your remote machine is good to go as long as the session is alive. 
.PARAMETER Functions
    The name of the functions/commands that need to be initialized on a remote session
.PARAMETER Session
    The PSSession of your remote target.
.NOTES
    Author - Zack
.EXAMPLE
    .\Invoke-LoadRemoteFunctions.ps1 -Functions "Write-Log", "Get-CustomFunction" -Session (New-PSSession -ComputerName Server1 -Credential (Get-Credential))
    
    Load functions Write-Log & Get-CustomFunction on Computer Server1.
.EXAMPLE
    .\Invoke-LoadRemoteFunctions.ps1 -Functions "Write-Log", "Get-CustomFunction" -Session $Session

    Load functions Write-Log & Get-CustomFunction into session $Session
.INPUTS
    System.Management.Automation.Runspaces.PSSession
.OUTPUTS
    None
.LINK
    Github: https://github.com/thonkerguns/PowerShell
#>
[CmdletBinding()]
Param(
    [Parameter(Mandatory,
        Position=0)]
    [System.String[]]$Functions,

    [Parameter(Mandatory,
        Position=1,
        ValueFromPipeline,
        ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
    [System.Management.Automation.Runspaces.PSSession]$Session
)

begin {
    $CommandDefinition = $null
    $HashTable = @{}

    # Cannot proceed if the session isn't opened
    if ($Session.State -ne 'Opened') {
        Write-Warning "Invoke-LoadRemoteFunctions: The provided Session's state is not open. Stopping"
        break
    }
}
Process {
    # Iterate through each provided function
    foreach ($Function in $Functions) {
        # Store the function into command $Command
        $FoundCommand = Get-Command -Name $Function -ErrorAction SilentlyContinue

        # If the command exists, retrieve the commandtype and its source code
        if ($FoundCommand) {
            $CommandDefinition = @"
                $($FoundCommand.CommandType) $function {
                    $($FoundCommand.Definition)
                }
"@
            # Store the Command & its source code/command type into the hashtable
            $HashTable.Add($function, $CommandDefinition)
        } else {
            Write-Warning "Invoke-LoadRemoteFunctions: Could not find command $Function, skipping."
        }
    }

    # Enter the provided remote session and begin loading the commands into the Script Scope
    try {
        Invoke-Command -Session $Session -ScriptBlock {
            # Store the passed hashtable so we can access its data ($using:hashtable[$key] gives an error)
            $Table = $using:hashtable

            # Iterate through each command and grab said command's definition (aka source code of said function)
            # This will load the function in the 'Script' scope for remote usage.
            foreach ($Key in $Table.keys) {
                . ([ScriptBlock]::Create($Table[$Key]))
            }
        } -ErrorAction Stop
    } catch {
        Throw $_
    }
}
