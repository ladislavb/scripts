##########################################################################################################################
# PS script to assign Intune managed devices to device group(s) based on primary user group membership
# Uses Microsoft.Graph module, is multiplatform and compatible with PowerShell Core 7.x
# See https://docs.microsoft.com/en-us/powershell/microsoftgraph/?view=graph-powershell-1.0 for MS Graph PowerShell SDK documentation
# Author: Ladislav Blažek <ladislav@lblazek.cz>
##########################################################################################################################

# Tenant configuration for unattended usage
# Leave empty for interactive script usage
# ========================================================================================================================

$tenantId = ""
$clientId = ""
$clientSecret = ""

# Base device filter
# ========================================================================================================================
# $deviceFilter = "" # Empty to fetch all devices
# $deviceFilter = "OperatingSystem eq 'iOS'" # iOS devices only
# $deviceFilter = "(OperatingSystem eq 'Android' or OperatingSystem eq 'iOS')" # Android or iOS devices

$deviceFilter = ""

# Enrolled within last X minutes
# ========================================================================================================================
# $enrolledWithinMinutes = 0 # Unlimited
# $enrolledWithinMinutes = 120 # Enrolled in last 120 minutes

$enrolledWithinMinutes = 60

# User group to device group mapping - device group can be used for automatic scope tag assignment
# Object Id from AAD is needed for both group types
# ========================================================================================================================

$userGroup2DeviceGroupMapping=@()
$hashTable = @{                         
    UserGroupId = "ccade9ca-b78c-4835-83de-178b66c7d5b3"
    DeviceGroupId = "a3a6b55c-75d3-4699-8bae-432b9326f618"
}                                              
$userGroup2DeviceGroupMapping+=(New-Object PSObject -Property $hashTable)
$hashTable = @{                       
    UserGroupId = "User Group ID"
    DeviceGroupId = "a3a6b55c-75d3-4699-8bae-432b9326f618"
}                                              
$userGroup2DeviceGroupMapping+=(New-Object PSObject -Property $hashTable)

# Microsoft.Graph module check
# ========================================================================================================================

if (Get-Module -ListAvailable -Name "Microsoft.Graph") {
    ""
    "===================================================================================="
    "Starting script"
    "===================================================================================="
    ""
    #Write-Host "All requirements has been met. Ready to go!"
} 
else {
    Write-Host "Microsoft.Graph Module is missing!!! Please install it first."
    exit
}

# Authentication
# a. Obtain Access Token using Client ID + Client Secret and connect to Graph API with the obtained Access Token instead of certificate
# b. Or use web browser for authentication
# ========================================================================================================================

if ($tenantId) {
    $body = @{
        grant_type = "client_credentials";
        client_id = $clientId;
        client_secret = $clientSecret;
        scope = "https://graph.microsoft.com/.default";
    }
    $response = Invoke-RestMethod -Method Post -Uri https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token -Body $body
    $accessToken = $response.access_token
    $accessToken
    Connect-MgGraph -AccessToken $accessToken
    "Running in unattended mode"
}
else {
    Connect-MgGraph -Scopes "Directory.Read.All","DeviceManagementManagedDevices.Read.All","GroupMember.ReadWrite.All"
    "Running in interactive mode"
}

#Select-MgProfile -Name "beta"

# Retrieve and cache device groups membership
# ========================================================================================================================

# Read all device groups from the mapping hash table into array
$deviceGroupIds = @()
foreach ($deviceGroup in $UserGroup2DeviceGroupMapping) {
    $deviceGroupIds += $deviceGroup.DeviceGroupId
}
# Filter out duplicate device group IDs
$uniqueDeviceGroupIds = $deviceGroupIds | Select-Object -Unique
# Cache data in a hash table for later use
$deviceGroupCache = @{}
# For every device group in the mapping table...
foreach ($deviceGroup in $uniqueDeviceGroupIDs) {
    # Fetch group members
    $deviceGroupMembership = Get-MgGroupMember -GroupId $deviceGroup -All | ForEach-Object {
        [pscustomobject]@{
            Id = $_.id
            DeviceId = $_.AdditionalProperties['deviceId']
        }
    }
    # Construct array containg all group member DeviceIds of particular device group
    $deviceGroupCache.$deviceGroup = @()
    foreach ($deviceObject in $deviceGroupMembership) {
        $deviceGroupCache.$deviceGroup += $deviceObject.DeviceId
    }
}

# Fetch managed devices and update device group membership when needed
# ========================================================================================================================

"Fetching managed devices..."

# Construct device filter condition
If ($enrolledWithinMinutes -and $enrolledWithinMinutes -ne 0) {
    $minutesago = "{0:s}" -f (get-date).addminutes(0-$enrolledWithinMinutes) + "Z"
    if ($deviceFilter) {
        $deviceFilter = "$deviceFilter and EnrolledDateTime ge $minutesAgo"
    }
    else {
        $deviceFilter = "EnrolledDateTime ge $minutesAgo"
    }
}
"Filter: " + $deviceFilter

# Fetch devices
$managedDevices = Get-MgDeviceManagementManagedDevice -Filter $deviceFilter -All
$managedDevicesCount = $managedDevices.count

"Result: " + $managedDevicesCount + " device(s) found"

# For every device...
$i = 1
foreach ($device in $managedDevices) {
    ""
    "- " + $i + "/" + $managedDevicesCount + " ------------------------------------------------------------------------------"
    "AAD Device ID: " + $device.AzureAdDeviceId
    "Device Name: " + $device.ManagedDeviceName
    "UPN: " + $device.UserPrincipalName
    ""
    # Fetch user groups of the primary user
    $userGroups = Get-MgUserMemberOf -UserId $device.UserId -All
    # For every user group...
    foreach ($userGroup in $userGroups) {
        # Check the mapping table
        if ($UserGroup2DeviceGroupMapping.UserGroupID -contains $userGroup.Id) {
            "-> Matched user group ID: " + $userGroup.Id
            # Get corresponding device group object ID from the mapping table
            foreach ($deviceGroup in $UserGroup2DeviceGroupMapping) {
                if ($deviceGroup.UserGroupID -eq $userGroup.Id) {
                    "--> User group ID mapped to device group ID: " + $deviceGroup.DeviceGroupID
                    # Device is already member of the device group
                    if ($deviceGroupCache.($deviceGroup.DeviceGroupID) -contains $device.AzureAdDeviceId) {
                        "---> NO CHANGE NEEDED"
                    }
                    # Device needs to be 
                    else {
                        "---> UPDATE"
                        # ToDo
                        # Get-MgDeviceManagementManagedDevice does not return Directory Object Ids for Intune managed devices
                        # Directory Object Id of a device is needed to update group membership
                        # Workaround: Use Get-MgDevice and search an Intune managed device in AAD by AzureADDeviceId and take Id field from there
                        # Maybe there is a better solution???
                        $filter = "deviceId eq '" + $device.AzureAdDeviceId + "'"
                        $directoryObject = Get-MgDevice -Filter $filter -Top 1
                        # Update group membership
                        New-MgGroupMember -GroupId $deviceGroup.DeviceGroupID -DirectoryObjectId $directoryObject.Id
                    }
                }
            }
        }
    }
    $i++
}

# Dicsonnect
# ========================================================================================================================
 
$Disconnect = Disconnect-MgGraph