<#
    .SYNOPSIS
    Updates a printer's location in Group Policy to point to a different Print Server (e.g., changes \\PRINTSERVER01\Call Center to \\PRINTSERVER02\Call Center).

    .DESCRIPTION
    Retrieves all printer GPO's and updates their shared path to a different print server (e.g., changes \\PRINTSERVER01\Call Center to \\PRINTSERVER01\Call Center)

    .PARAMETER NewPrintServer
    Specifies the new printer server you want the printers in group policy to point to (e.g., PRINTSERVER02)

    .EXAMPLE
    The following example will update the printer GPOs to point to PRINTSERVER02
    PS> .\Migrate-Printers.ps1 -NewPrintServer 'PRINTSERVER02' -domain mycompany.com
#>
[cmdletbinding()]
param (
    [parameter(Mandatory,
        helpmessage="Enter the new print server you want the printer GPOs to point to (e.g., PRINTSERVER02)")]
    [ValidateNotNullOrEmpty()]
    [string]$NewPrintServer,

    [parameter(Mandatory,
        helpMessage="What is your domain's name? (e.g., contoso.com)")]
    [ValidateNotNullOrEmpty()]
    [string]$Domain
)

#region Variables

# The regular expression naming scheme of your print servers (e.g., PRINTSERVER01 or PRINTSERVER02)
$NAMING_SCHEME = '^PRINTSERVER[0-9][0-9]$'

# The GPO Naming scheme of your group policy objects (e.g., Printer - Finance)
# The below will match any GPO like 'Printer - NAME_HERE'
$GPO_NAMING_SCHEME = 'Printer - *'

#endregion

#region Modules
# Import Group Policy Module
if (-not (Get-Module -Name GroupPolicy -ErrorAction SilentlyContinue)) {
    Import-Module -name GroupPolicy

    if (Get-Module -Name GroupPolicy -ErrorAction SilentlyContinue) {
        Write-Host -ForegroundColor Green "Module Group Policy has been imported!"
    } else {
        Throw "Failed to import module Group Policy, stopping."
        break
    }
}

# Import Active Directory Module
if (-not (Get-Module -Name ActiveDirectory -ErrorAction SilentlyContinue)) {
    Import-Module -name ActiveDirectory

    if (Get-Module -Name ActiveDirectory -ErrorAction SilentlyContinue) {
        Write-Host -ForegroundColor Green "Module Active Directory has been imported!"
    } else {
        Throw "Failed to import module Active Directory, stopping."
        break
    }
}
#endregion

# Strip out the domain if it were given
if ($NewPrintServer.Contains('.')) {
    $NewPrintServer = $NewPrintServer.Split('.')[0]
}

# Make sure NewPrintServer fits our naming scheme for print servers
if ($NewPrintServer -notmatch $NAMING_SCHEME) {

    # Repeat until it matches our criteria
    do {
        # Ask the user for a new print server
        $NewPrintServer = Read-Host "Enter the hostname of the print server you want the printers to point to (e.g., $NAMING_SCHEME)"
        # Strip out .mycompany.com if it were given
        if ($NewPrintServer.Contains('.')) {
            $NewPrintServer = $NewPrintServer.Split('.')[0]
        }

    } until ($NewPrintServer -match $NAMING_SCHEME)
}

# Grab all Printer GPOs
$PrinterGPOs = Get-GPO -All | Where-Object DisplayName -like $GPO_NAMING_SCHEME

# If we got something, start the process
if ($PrinterGPOs) {
    # Begin Iterating through each GPO
    foreach ($printer in $PrinterGPOs) {
        
        Write-Host -ForegroundColor Yellow "`nCurrent GPO: $($Printer.DisplayName)."

        # Grab current printer's GPO GUID
        [string]$CurrentGUID = $Printer | Select-Object -ExpandProperty id

        # Create Path of XML with the given GPO GUID
        $GPOxmlFile = "\\$domain\sysvol\$domain\Policies\{$CurrentGUID}\User\Preferences\Printers\Printers.xml"

        # Get GPO XML that holds the printer settings
        [xml]$PrinterXML = Get-Content -Path $GPOxmlFile -ErrorAction SilentlyContinue

        if ($PrinterXML) {
            
            # Current Printer Path
            $CurrentPrinterPath = $PrinterXML.printers.PortPrinter.Properties.path
            
            # If CurrentPrintServer wasn't added, fill it out here
            if (-not ($CurrentPrintServer)) {
                Write-Host -ForegroundColor Yellow "CurrentPrintServer wasn't given, grabbing that now."
                $CurrentPrintServer = $($CurrentPrinterPath.split('\')[2])
            }

            # Make sure the current printer's location doesn't equal the new location. If it does, skip it.
            if (-not ($CurrentPrinterPath.Contains($NewPrintServer))) {
                
                Write-Host -ForegroundColor Yellow "GPO $($Printer.DisplayName)'s Print Server is not currently set to $NewPrintServer."
                Write-Host -ForegroundColor Yellow "Setting GPO $($Printer.DisplayName)'s Print server to $NewPrintServer from $CurrentPrintServer"
                # Update Printer's Location
                $PrinterXML.printers.PortPrinter.Properties.path = "\\$NewPrintServer\$($CurrentPrinterPath.Split('\')[-1])"

                # Grab the new Printer Path from the XML file
                $NewPrinterPath = $PrinterXML.printers.PortPrinter.Properties.path

                # Verify if the XML was updated correctly
                if ($NewPrinterPath.Contains($NewPrintServer)) {
                    
                    try {
                        $PrinterXML.Save($GPOxmlFile)
                        Write-Host -ForegroundColor Green "Successfully updated GPO $($Printer.DisplayName)'s Print Server from $CurrentPrintServer to $NewPrintServer"
                    } catch {
                        Write-Error "Failed to save XML file for GPO $($Printer.DisplayName)."
                    }
                } else {
                    Write-Warning "GPO $($Printer.DisplayName) did not update from $CurrentPrintServer to $NewPrintServer."
                }
                
            } else {
                Write-Host -ForegroundColor Green "GPO $($Printer.DisplayName) is already set to $NewPrintServer!"
            }
        } else {
            Write-Warning "Failed to gather XML file for GPO $($Printer.DisplayName)"
        }

        # Reset CurrentPrintServer as I'm having issues understanding why it's causing issues
        $CurrentPrintServer = $null
    }
} else {
    Write-Error "Didn't find any Printer GPOs."
}
