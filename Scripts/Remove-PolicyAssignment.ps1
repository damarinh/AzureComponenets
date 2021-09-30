# region parameters
param (
    [Parameter(Mandatory=$true)][string]$rootFolder,
    [Parameter(Mandatory=$true)][string]$assignmentNames,
    # location of policies and initiatives
    [Parameter(Mandatory = $true)][string]$definitionLocation
)
#endregion

$assignmentPath = $RootFolder + $assignmentNames

Write-Host "##[section] Creating $assignmentNames Policy/Initiative"
Write-Host "##[debug]     Assignment Def Path: $assignmentPath"

$assignmentDef = Get-Content -Path $assignmentPath | ConvertFrom-Json

switch ($assignmentDef.scopeGroupList.name){
    'mgmt group' {$scope = Get-AzManagementGroup -GroupName $definitionLocation; break}
    'Subscription' {$scope = Get-AzSubscription -SubscriptionName $definitionLocation; break}
}

Write-Host "##[debug]     Remove Scope: $scope"

$scopeId = $scope.id

Write-Host "Looking up policies and initiative at the Tenant Root Group scopes"

$assignment = Get-AzPolicyAssignment -Name $assignmentDef.scopeGroupList.assignmentName -Scope $scopeId -ErrorAction SilentlyContinue
        
if ($assignment) {
   Write-Host "##{debug}       Rolling back assignment"
   try
   {
       Write-Host "##{debug}       Removing assignment"
       Write-host $assignment.Identity.PrincipalId
       #Remove todos os permissionamentos RBACs das contas excluídas do Azure AD
       #start testing section
       $RoleAssignments = Get-AzRoleAssignment -Scope $scopeId
       Write-Host "## Trying to retrieve single PolicyAssignment"
       $objectId = $assignment.Identity.PrincipalId
       #Get-AzRoleAssignment -Scope $scopeId -ObjectId $objectId
       #end testing section
       #$RoleAssignments = Get-AzRoleAssignment -ObjectId $assignment.Identity.PrincipalId
       Write-Host "##{debug}       $objectId"
       #Checking if there any role assigned to a log analytics and removing it if it exists
       if($assignment.Properties.parameters.logAnalytics.value){
            
            $RoleAssignmentsLAW = Get-AzRoleAssignment -scope $assignment.Properties.parameters.logAnalytics.value
            Write-Host "##{debug}       Retrieving Role assignments LAW"
            foreach ($RoleAssignmentLAW in $RoleAssignmentsLAW) 
            { 
                if($RoleAssignmentLAW.ObjectId -eq  $objectId){
                    Write-Host "##{debug}       Removing Role assignments $RoleAssignmentLAW"
                    Remove-AzRoleAssignment -InputObject $RoleAssignmentLAW -Verbose    
                }
            }
       }
       
       #Checking the managed identity roles and removing them at the management group
       foreach ($RoleAssignment in $RoleAssignments) 
       { 
            if($RoleAssignment.ObjectId -eq  $objectId){
                Write-Host "##{debug}       Removing Role assignments $RoleAssignment"
                Remove-AzRoleAssignment -InputObject $RoleAssignment -Verbose    
            }           
       }
   }
   catch
   {
       Trace "$_" -Type 'Error'
   }

   Remove-AzPolicyAssignment -Name $assignmentDef.scopeGroupList.assignmentName  -Scope $scopeId

 }
else {
   Write-Host "##{debug}      Assignment not assigned at scope: $scopeId"
}
#endregion
