param (
    [Parameter(Mandatory = $true)][string]$rootFolder,
    [Parameter(Mandatory = $true)][string[]]$assignmentNames,
    # location of policies and initiatives
    [Parameter(Mandatory = $true)][string]$definitionLocation,
    [Parameter(Mandatory = $true)][string]$managementgroupname
)

function TrimLength {
    param (
        [parameter(Mandatory = $True, ValueFromPipeline = $True)] [string] $Str
        , [parameter(Mandatory = $True, Position = 1)] [int] $Length
    )
    $Str[0..($Length - 1)] -join ""   
}

if ($assignmentNames -eq $null) {
    Write-Host "##vso[task.LogIssue type=warning;]No Assignment diffs found or only deleted files found, skiping..."
}
else {
    foreach ($assignmentFileName in $assignmentNames) {

        $assignmentPath = $RootFolder + $assignmentFileName

        Write-Host "##[section] Creating Assignmnet `"$assignmentFileName`""

        $assignmentDef = Get-Content -Path $assignmentPath | ConvertFrom-Json

        # Processing  Assignmnet level properties
        $whatToAssign = @{}
        $lookup = $null
        $list = @()
        $name = " "
        $isInitiative = $false
        if ($assignmentDef.initiativeName) {
            $name = $assignmentDef.initiativeName
            $isInitiative = $true
            Write-Host "##[section] Processing Initiative $($name)"
            if ($definitionLocation) {
                $list = Get-AzPolicySetDefinition -ManagementGroupName $definitionLocation
            }
            else {
                # Subscription
                $list = Get-AzPolicySetDefinition
            }
        }
        elseif ($assignmentDef.policyName) {
            $name = $assignmentDef.policyName
            Write-Host "##[section] Processing Policy $($name)"        
            if ($definitionLocation) {
                $list = Get-AzPolicyDefinition -Name $name -ManagementGroupName $definitionLocation
            }
            else {
                # Subscription
                Write-Host "##[debug]       Object `"$name`" - not stored in the Management Group" 
                $list = Get-AzPolicyDefinition -Id "/providers/Microsoft.Authorization/policyDefinitions/$name"
            }
        }
        else {
            Write-Host  ($assignmentDef | ConvertTo-Json -depth 100)
            Throw "Neither policyName nor initiativeName specified - must specify one (only)"
        }

        # Does the Initiative or Policy
        $lookup = $list | Where-Object { ($_.Properties.DisplayName -eq $name) -or ($_.Name -eq $name) }
        if ($null -eq $lookup) {
            Write-Host "##[debug]       Object `"$name`" - not found"            
            Throw "Assignment must specify a valid ""initiativeName"" or a ""policyName"" object"
        }
        if ($lookup -is [array]) {
            # pick first item if multiple found (shoudn't happen)
            $lookup = $lookup[0]
        }
        #Write-Host  ($lookup | ConvertTo-Json -depth 100)
        If ($isInitiative) {
            $whatToAssign["PolicySetDefinition"] = $lookup
        }
        else {
            $whatToAssign["PolicyDefinition"] = $lookup
        }
        
        # Initialize parameter collection
        $definedParameters = $lookup.Properties.Parameters

        # Set Assignment level parameter values
        $parametersAtLevel = $assignmentDef.Parameters
        $parameterObject = @{}
        if ($parametersAtLevel -ne $null -and $definedParameters -ne $null) {
            foreach ($definedParameter in $definedParameters.psobject.Properties) {
                $parameterName = $definedParameter.Name
                foreach ($parameterAtLevel in $parametersAtLevel.psobject.properties) {
                    if ($parameterAtLevel.Name -eq $parameterName) {
                        Write-Host "##[Debug]       Setting param $parametername to Assignmnet level value $($parameterAtLevel.Value)"
                        $parameterObject[$parameterName] = $parameterAtLevel.Value
                        break
                    }
                }
            }
        }
        $assignmentLevelParameterObject = $parameterObject

        # Process scopeGroup array
        foreach ($scopeGroup in $assignmentDef.ScopeGroupList) {
            $scopeGroupName = $scopeGroup.Name
            $assignmentName = $scopeGroup.AssignmentName | TrimLength 24
            if($scopeGroup.displayName){
                $assignmentDisplayName = $scopeGroup.displayName | TrimLength 64
            }else{
                $assignmentDisplayName = $scopeGroup.AssignmentName | TrimLength 64
            }

            # Set scopeGroup level parameter values
            $parametersAtLevel = $scopeGroup.Parameters
            $parameterObject = $assignmentLevelParameterObject
            if ($parametersAtLevel -ne $null -and $definedParameters -ne $null) {
                foreach ($definedParameter in $definedParameters.psobject.Properties) {
                    $parameterName = $definedParameter.Name
                    foreach ($parameterAtLevel in $parametersAtLevel.psobject.properties) {
                        if ($parameterAtLevel.Name -eq $parameterName) {
                            Write-Host "##[Debug]       Setting param $parametername to ScopeGroup level value $($parameterAtLevel.Value)"
                            $parameterObject[$parameterName] = $parameterAtLevel.Value
                            break
                        }
                    }
                }
            }
            $scopeGroupLevelParameterObject = $parameterObject
            
            # Process scopeList
            foreach ($scopeDef in $scopeGroup.ScopeList) {

                # get managementgroupID or subscriptionID (formated correctly)
                if ($null -ne $scopeDef.ManagementGroupName) {
                    $scope = (Get-AzManagementGroup -GroupName $managementgroupname).Id
                }
                elseif ($null -ne $scopeDef.SubscriptionName) {
                    $scope = "/subscriptions/$((Get-AzSubscription -SubscriptionName $scopeDef.SubscriptionName).Id)"
                }
                else {
                    Throw "Scope must specify an ""managementGroupName"" or a ""subscriptionName"" item"
                }
                Write-Host "##[debug]     Assignment Scope: $scope"

                # Set scope level parameter values
                $parametersAtLevel = $scopeDef.Parameters
                $parameterObject = $scopeGroupLevelParameterObject
                if ($parametersAtLevel -ne $null -and $definedParameters -ne $null) {
                    foreach ($definedParameter in $definedParameters.psobject.Properties) {
                        $parameterName = $definedParameter.Name
                        foreach ($parameterAtLevel in $parametersAtLevel.psobject.properties) {
                            if ($parameterAtLevel.Name -eq $parameterName) {
                                Write-Host "##[Debug]       Setting param $parametername to Scope level value $($parameterAtLevel.Value)"
                                $parameterObject[$parameterName] = $parameterAtLevel.Value
                                break
                            }
                        }
                    }
                }

                # Create  Assignment at scope
                $createAssignment = @{
                    "Name"                  = $assignmentName
                    "DisplayName"           = $assignmentDisplayName
                    "Description"           = $lookup.Properties.Description
                    "Scope"                 = $scope
                    "PolicyParameterObject" = $parameterObject
                }
                $createAssignment += $whatToAssign
                if ($scopeDef.notScope) {
                    $createAssignment["NotScope"] = $scopeDef.notScope
                }
                
                #$assignment = Get-AzPolicyAssignment -Name $assignmentName -Scope $scope -ErrorAction SilentlyContinue
        
                #if ($assignment) {
                #         Write-Host "##{debug}      Assignment already exists"
                #}
                #else {
                #        Write-Host "##{debug}      Assignment not assigned at scope: $scopeId"
                        $assignment = New-AzPolicyAssignment @createAssignment -AssignIdentity -Location "eastus"
                #}
                
                $roleDefinitionIds = $lookup.Properties.policyRule.then.details.roleDefinitionIds         
                
                if($isInitiative){
                    $definition = Get-AzPolicyDefinition -Id $lookup.Properties.policyDefinitions[0].policyDefinitionId
                    $roleDefinitionIds = $definition.Properties.policyRule.then.details.roleDefinitionIds
                }

                if ($roleDefinitionIds.Count -gt 0)
                {
                    
                    $roleDefinitionIds | ForEach-Object {
                        $roleDefId = $_.Split("/") | Select-Object -Last 1
                        $role = Get-AzRoleAssignment -Scope $scope -ObjectId $assignment.Identity.PrincipalId -RoleDefinitionId $roleDefId
                        if ($role){
                            Write-Host "##{debug}       Role Assignment already exists"
                        }
                        else{
                            Start-Sleep -s 50
                            New-AzRoleAssignment -Scope $scope -ObjectId $assignment.Identity.PrincipalId -RoleDefinitionId $roleDefId
                            Write-Host "##{debug}       Role $roleDefId Assigned "
                        }
                        
                         foreach ($resourceid in $parameterObject.Values) {
    
                            if ($resourceid.Contains('microsoft.operationalinsights/workspaces')){
                                 Write-Output "Loganalytics"
                                 $roleresource = Get-AzRoleAssignment -Scope $resourceid -ObjectId $assignment.Identity.PrincipalId -RoleDefinitionId $roleDefId
                                 if ($roleresource){
                                     Write-Host "##{debug}       Role Assignment $roleDefId Assigned in the Resource already exists"
                                 }
                                 else{
                                     New-AzRoleAssignment -Scope $resourceid -ObjectId $assignment.Identity.PrincipalId -RoleDefinitionId $roleDefId
                                     Write-Host "##{debug}       Role $roleDefId Assigned "
                                 }
                            }elseif($resourceid.Contains('microsoft.storage/storageAccounts')){
                                Write-Output "StorageAccount"
                                 $roleresource = Get-AzRoleAssignment -Scope $resourceid -ObjectId $assignment.Identity.PrincipalId -RoleDefinitionId $roleDefId
                                 if ($roleresource){
                                     Write-Host "##{debug}       Role Assignment $roleDefId Assigned in the Resource already exists"
                                 }
                                 else{
                                     New-AzRoleAssignment -Scope $resourceid -ObjectId $assignment.Identity.PrincipalId -RoleDefinitionId $roleDefId
                                     Write-Host "##{debug}       Role $roleDefId Assigned "
                                 }
                            }else{
                                Write-Output "No role assignment required on resource"
                            }
                         }       
                    }
                }
            }
        }
    }
}
