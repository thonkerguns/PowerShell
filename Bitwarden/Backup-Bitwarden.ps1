<#
.Synopsis
    This script performs a backup operation on an on-premise (Ubuntu Server 22.04) bitwarden server.

.DESCRIPTION
    This script will create full or incremental backups of Bitwarden. It will create the backup, encrypt the backup, 
    delete the unecnrypted backup, verify the encrypted backup exists, move said encrypted backup to its final destination (e.g., a mounted file share), 
    and perform any cleanup if backups are older than a given age.

.NOTES
    Author - Zack

    Script Environment:
        OS: Ubuntu Server 22.04 LTS
        Packages Used:
            - gpg
            - tar
            - pwsh - Version 7.2.3

    To use this script, update the following variables to match your environment:
        - IMPORTANT_DIRECTORIES
        - VAULT_LOG (if you plan to use the incremental switch)
    
    To send Emails, populate the appropriate fields in function Send-EmailNotification 

.PARAMETER PasswordFile
    The password file that holds the passphrase that will be used to encrypt backups.

.PARAMETER FinalBackupLocation
    The destination of the encrypted backup (e.g., '/path/to/mounted/location/bitwarden')

.PARAMETER EmailAddresses
    The email address(es) in which notifications will be sent out to.

.PARAMETER BackupIfChanges
    This switch will backup if there's been any changes to the Bitwarden database within the past hour. 

.PARAMETER Days
    The amount of days to keep backups. For example, if you set this to '10', the script will delete all backups greater than 10 days from current date. You must also
    give the correct backup location that houses said existing backups (e.g., /path/to/mounted/location/bitwarden)

.PARAMETER LogFile
    The location where the log file will reside.

.EXAMPLE
    ./Backup-Bitwarden.ps1 -PasswordFile '/opt/bitwarden/password_file' -FinalBackupLocation '/path/to/mounted/location/bitwarden'
    
    Backup BitWarden with the default retention days of 14 and store the backups at location /path/to/mounted/location/bitwarden

.EXAMPLE
    ./Backup-Bitwarden.ps1 -PasswordFile './password_file' -days 5 -FinalBackupLocation '/path/to/mounted/location/bitwarden' -EmailAddresses 'test.user@mycompany.com'
    
    Backup BitWarden with a retention of 5 days (this will remove backups older than 5 days) and store the backup at /path/to/mounted/location/bitwarden'

.EXAMPLE
    ./Backup-Bitwarden.ps1 -PasswordFile '/opt/bitwarden/password_file' -FinalBackupLocation '/path/to/mounted/location/bitwarden' -days 10 -LogFile '/root/bitwarden_backup.log'
    
    Backup Bitwarden with the provided password file and cleanup backups to only allow 10 days worth of backups to be stored at the final destination. Also, 
    set the script's log file to be stored at /root/bitwarden_backup.log'

.EXAMPLE
    ./Backup-Bitwarden.ps1 -PasswordFile '/opt/bitwarden/password_file' -FinalBackupLocation '/path/to/mounted/location/bitwarden -Days 14 -BackupIfChanges

    Perform the incremental backup job (if changes were within the last hour). with an encryption password located in the provided passwordfile. 
    If a backup were to be created, it will check for backups in the FinalBackupLocation that meet the passed days (14).
    Any backups older than the 14 days within the FinalBackupLocation will be deleted. 

#>
[cmdletbinding()]
param (
    [parameter(Mandatory,
        Position=0)]
    [string]$PasswordFile,

    [parameter(Mandatory,
        Position=1)]
    [string]$FinalBackupLocation,

    [Parameter(Mandatory=$false)]
    [string[]]$EmailAddresses,

    [parameter(Mandatory=$false,
        helpMessage="Delete backups that are older than the given day (e.g., if you enter 5, backups older than 5 days from current day will be deleted)")]
    [ValidateRange(1, 100)]
    [int]$Days = 31,

    [parameter(Mandatory=$false)]
    [switch]$BackupIfChanges,

    [Parameter(Mandatory=$false)]
    [string]$LogFile = './backup-bitwarden.log'
)

#region VARIABLES
$script:LOG_FILE = $LogFile

# What directories should we backup?
# I believe these are the default directories for Bitwarden if you follow Bitwarden's installation guide
$IMPORTANT_DIRECTORIES = "/opt/bitwarden/bwdata/env", "/opt/bitwarden/bwdata/core/attachments", "/opt/bitwarden/bwdata/mssql/data"

# Path of the Vault log (this is used to determine if we need to make an incremental backup (if -BackupIfChanges were passed))
$VAULT_LOG = "/opt/bitwarden/bwdata/mssql/data/vault_log.ldf"

# Final backup location should be '/path/to/mounted/location/bitwarden/'
$FINAL_BACKUP_LOCATION = $FinalBackupLocation

#endregion

#region FUNCTIONS
function Write-Log
{
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param
    (
        [parameter(Mandatory = $false,
                    Position = 0)]
        [string]$Path = $script:LOG_FILE,
        [Parameter(Position = 1,
                    Mandatory = $true,
                    ParameterSetName = 'Default')]
        [ValidateSet('Verbose', 'Information', 'Warning', 'Error')]
        [String]$EntryType,
        [Parameter(Position = 2,
                    Mandatory = $true,
                    ParameterSetName = 'Default')]
        [String]$Message
    )
    
    begin
    {
        
        # Check if the log level an error or an error record was submitted
        if ($PSCmdlet.ParameterSetName -eq 'Default' -and $EntryType -eq 'Error')
        {
            $ErrorRecord = New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList $Message, 'Unknown', 'NotSpecified', $null
        }
    }
    
    process
    {
        # Output to file
        $Line = "[$EntryType][$((Get-Date).toString('yyyy-MM-dd:hh-mm-ss'))][$env:ComputerName], $Message"
        $Line | Out-File $Path -Append
        
        switch ($EntryType)
        {
            'Verbose'     { Write-Verbose -Message $Message }
            'Information' { Write-Host $Message }
            'Warning'     { Write-Warning -Message $Message }
            'Error'       { Write-Error -ErrorRecord $ErrorRecord }
        }
    }
}

function Send-EmailNotification {
    [cmdletbinding()]
    param (
        [string]$From,
        [string]$SMTPServer,
        [string]$Subject,
        [string]$Body,
        [string[]]$EmailAddresses
    )
    
    end {
        Send-MailMessage -To $EmailAddresses -From $From -Subject $Subject -BodyAsHtml -Body $Body -SmtpServer $SMTPServer
    }
}

function Get-BackupName {
    end {
        Write-Log -EntryType Information -Message "Get-BackupName: Creating a new backup name..."
        return "BitWardenBackup-$((Get-Date).toString('yyyy-MM-dd_HH-mm-ss')).tar"
    }
}
function New-Backup {
    [cmdletbinding()]
    param (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Items,

        [parameter(Mandatory=$false)]
        [string]$LogFile = $script:LOG_FILE
    )

    begin {
        if ($null -eq $Items -or $Items -eq "") {
            Write-log -EntryType Error -Message "New-Backup: There were 0 items given to backup, stopping."
            break
        }
        # Create name of backup
        $BackupName = Get-BackupName

        # Store the location of the successful backup
        $BackupLocation = $null

        # Did we succeed?
        $Success = $false
    }

    process {
        # Begin Backup Process
        Write-Log -entrytype information -Message "New-Backup: Creating backup $BackupName..."
        foreach ($Item in $Items) {
            if (-not (Test-Path -Path $BackupName)) {
                tar -cf $BackupName $Item
            } else {
                tar -rf $BackupName $Item
            }
        }

        if (-not (Test-Path -Path $BackupName)) {
            Write-Log -EntryType Error -Message "New-Backup: Did not create backup $BackupName..."
        } else {
            Write-Log -entrytype Information -Message "New-Backup: Successfully created backup $BackupName!"
            $BackupLocation = Get-Item -Path $BackupName | Select-Object -ExpandProperty FullName
            $Success = $true
        }
    }

    end {
        if ($Success) {
            return $BackupLocation
        } else {
            return $null
        }
    }
}

function Encrypt-Backup {
    [cmdletbinding()]
    param (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupFileLocation,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PasswordFileLocation
    )

    begin {

        # Validate if the provided BackupFileLocation & PasswordFile exist
        if (-not (Test-Path -path $BackupFileLocation)) {
            Write-Log -EntryType error -Message "Encrypt-Backup: The provided BackupFileLocation ($BackupFileLocation) does not exist, stopping."
        }

        if (-not (Test-Path -path $PasswordFileLocation)) {
            Write-Log -EntryType error -Message "Encrypt-Backup: The provided PasswordFileLocation ($PasswordFileLocation) does not exist, stopping."
        }

        # This will return true if encryption was successful
        $Success = $false

        # Encrypted Backup File Location
        $EncryptedBackupLocation = "$($BackupFileLocation).gpg"
    }

    process {
        Write-Log -EntryType information -Message "Encrypt-Backup: Attempting to encrypt backup $BackupFileLocation with Password File $PasswordFileLocation"
        Get-Content -Path $PasswordFileLocation | gpg --batch -c --passphrase-fd 0 $BackupFileLocation

        # Test if encryption was successful
        if (Test-Path -Path $EncryptedBackupLocation) {
            Write-Log -EntryType Information -Message "Encrypt-Backup: Successfully encrypted backup $BackupFileLocation."
            $Success = $true
        } else {
            Write-Log -EntryType Error -Message "Encrypt-Backup: Could not find encrypted backup $EncryptedBackupLocation"
            $Success = $false
        }
    }

    end {
        if ($Success) {
            return $EncryptedBackupLocation
        } else {
            return $null
        }
    }
}
function Delete-Backups {
    [cmdletbinding()]
    param (
        [parameter(Mandatory)]
        [ValidateRange(1,31)]
        [int]$Days,

        [Parameter(Mandatory)]
        [string]$BackupLocation
    )

    begin {
        # Check if the backup location actually exists.
        if (-not (Test-Path -Path $BackupLocation)) {
            Write-Log -EntryType Error -Message "Delete-Backups: Backup Location $BackupLocation does not exist, stopping."
            break
        }
        # Backups older than this date will get deleted
        $RetentionDate = (Get-Date).AddDays(-$Days)

        # Retrieve the full path of the old backups
        $OutDatedBackups = Get-ChildItem -Path $BackupLocation -erroraction silentlyContinue | Where-Object {$_.Name -like "*.gpg" -and $_.LastWriteTime -lt $RetentionDate} | Select-Object -ExpandProperty FullName
    }

    process {

        if ($null -ne $OutDatedBackups -and $OutDatedBackups -ne "") {
            # Creating a loop so I can log each deletion
            foreach($Backup in $OutdatedBackups) {
                Write-Log -EntryType Information -Message "Delete-Backups: Attempting to delete backup $Backup."
                Remove-Item -Path $Backup -whatif
            }
        } else {
            Write-Log -entrytype Information -Message "Delete-Backups: There isn't any backups older than $(($RetentionDate).toString('yyyy-MM-dd'))."
        }
    }
}
#endregion

#region Script running

#region Test Final Destination
if (-not (Test-Path -Path $FINAL_BACKUP_LOCATION)) {
    Write-Log -EntryType Error -Message "Main: Final Backup Location ($FINAL_BACKUP_LOCATION) does not exist, stopping."
    break
}
#endregion


#region Get Password for encryption
if (-not (Test-Path -Path $PasswordFile)) {
    Write-log -EntryType Error -Message "Main: Password file does not exist, make sure it's located at $PasswordFile."
    break
} else {
    # Retrieve password from password file
    Write-Log -EntryType Information -Message "Main: Retrieving passphrase from file $PasswordFile..."
    $Passphrase = Get-Content -Path $PasswordFile

    if ($null -eq $Passphrase -or $Passphrase -eq "") {
        Write-log -EntryType Error -Message "Main: Password file exists but it's empty, stopping."
        break
    }
}
#endregion

#region Create Backup

# If the user passed the BackupIfChanges switch, check for any vault changes within the past hour
if ($BackupIfChanges) {
    
    Write-Log -EntryType Information -Message "`nMain: Checking if the Vault has had any action within the past hour..."
    # Check if Bitwarden's Vault Log has had any changes within the past hour
    # If this is true, create incremental backup.
    if (Get-Item -Path $VAULT_LOG | Where-Object {$_.LastWriteTime -ge ((Get-Date).AddHours(-1))}) {
        Write-Log -EntryType Information -Message "Main: Vault has changed within the hour, creating Backup..."

        # Create backup
        $Backup = New-Backup -Items $IMPORTANT_DIRECTORIES
    } else {
        Write-Log -EntryType Information -Message "Main: Vault hasn't changed within the past hour, no need for a backup. Stopping script."
        break
    }
} else {
    # Didn't pass -BackupIfChanges, performing routine backup.
    Write-Log -EntryType Information -Message "`nMain: Creating Backup..."
    $Backup = New-Backup -Items $IMPORTANT_DIRECTORIES
}

# Check if we have a backup name. If we do, we can proceed to encryption.
if ($null -eq $Backup -or $Backup -eq "") {
    Write-Log -EntryType error -Message "Main: Failed to create backup for BitWarden, stopping."
    
    if ($EmailAddresses) {
        Send-EmailNotification -EmailAddresses $EmailAddresses -Subject "FAILURE: BitWarden Backup" -Body "Failed to create a backup for BitWarden."
    }
    break
} else {
    Write-Log -EntryType Information -Message "Main: Successfully created backup $Backup, begin encryption."
}
#endregion

#region Encrypt Backup

try {
    Write-Log -EntryType Information -Message "`nMain: Attempting to encrypt Backup $Backup."
    $EncryptedBackup = Encrypt-Backup -BackupFileLocation $Backup -PasswordFileLocation $PasswordFile -erroraction stop
} catch {
    $Message = $_
    Write-Log -entrytype Error -Message "Main: Failed to encrypt backup $Backup because of error $Message"
    if ($EmailAddresses) {
        Send-EmailNotification -EmailAddresses $EmailAddresses -Subject "FAILURE: BitWarden Backup" -Body "Encryption was successful but failed to delete unencrypted backup because of error: $Message"
    }
    break
}


# Stop the script if encryption wasn't successful
if ($null -eq $EncryptedBackup -or $EncryptedBackup -eq "") {
    Write-Log -EntryType Error -Message "Main: Failed to create encrypted backup. Deleting Backup & Stopping..."

    # Remove Backup as encryption failed
    Remove-Item -Path $Backup -erroraction Stop

    # Send Email about encryption failure
    if ($EmailAddresses) {
        Send-EmailNotification -EmailAddresses $EmailAddresses -Subject "FAILURE: BitWarden Backup" -Body "Backup succeeded but encryption failed. Deleting backup as we cannot encrypt it."
    }
    break
} else {
    # Encryption was successful, delete unencrypted backup
    Write-Log -entrytype Information -Message "`nMain: Encryption was successful, removing unencrypted backup."
    try {
        Remove-Item -Path $Backup -erroraction stop
    } catch {
        $Message = $_
        Write-Log -entrytype Error -Message "Main: Failed to remove backup $Backup because of error $Message"
        Send-EmailNotification -EmailAddresses $EmailAddresses -Subject "FAILURE: BitWarden Backup" -Body "Encryption was successful but failed to delete unencrypted backup because of error: $Message"
        break
    }

    # Move Encrypted Backup to Final Destination
    try {
        # We'll need to verify if the encrypted backup was moved afterwards
        $EncryptedBackupFinalLocation = "$FINAL_BACKUP_LOCATION/$(Get-Item -Path $EncryptedBackup | Select-Object -ExpandProperty Name)"

        Write-Log -entrytype Information -Message "`nMain: Moving Encrypted Backup to final backup destination ($FINAL_BACKUP_LOCATION)."
        Move-Item -Path $EncryptedBackup -Destination $FINAL_BACKUP_LOCATION -erroraction Stop
    } catch {
        $Message = $_
        Write-Log -entrytype Error -Message "Main: Failed to move encrypted backup $EncryptedBackup because of error $Message"
        if ($EmailAddresses) {
            Send-EmailNotification -EmailAddresses $EmailAddresses -Subject "FAILURE: BitWarden Backup" -Body "Main: Failed to move encrypted backup $EncryptedBackup because of error $Message"

        }
        break
    }

    # Verify the backup is at its final location
    if (Test-Path -Path $EncryptedBackupFinalLocation) {
        Write-Log -EntryType Information -Message "`nMain: Successfully created backup $EncryptedBackupFinalLocation. Sending success email."
        if ($EmailAddresses) {
            Send-EmailNotification -EmailAddresses $EmailAddresses -Subject "SUCCESS: BitWarden Backup" -Body "Main: Successfully created backup $EncryptedBackupFinalLocation."
        }
    } else {
        Write-Log -EntryType Error -Message "Main: Could not find created backup $EncryptedBackupFinalLocation."
    }
}
#endregion

#region Delete outdated backups
try {
    # Delete Backups older than $Days at backup location $FINAL_BACKUP_LOCATION
    Write-Log -EntryType Information -Message "`nMain: Check if there's any backups that are more than $Days days old."
    Delete-Backups -Days $Days -BackupLocation $FINAL_BACKUP_LOCATION -erroraction Stop
} catch {
    $Message = $_
    Write-Log -entrytype Error -Message "Main: Failed to remove outdated backups due to error $Message."
    break
}
#endregion
#endregion
