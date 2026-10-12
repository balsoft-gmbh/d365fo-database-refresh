<#
.SYNOPSIS
    Runs the Database refresh tasks of a Finance and Operations environment through the BDR service and
    waits until the job is finished.

.DESCRIPTION
    1. Gets a token for the environment URL with the client credentials of an Entra ID application that is
       registered in Finance and Operations (System administration > Setup > Microsoft Entra ID
       applications) with a user that has the role Database refresh administrator.
    2. Waits until the environment answers, because right after a copy it can take a while.
    3. Calls BDRService/run. Values for secrets named in the setup are read from environment variables
       BDR_SECRET_<name> and passed with the call; they are never written to the log.
    4. If the job continues in batch (data cleanup), polls BDRService/getJobStatus until it is finished.
    5. Prints the result of every task and exits with code 1 if the job did not succeed.

.EXAMPLE
    $env:BDR_CLIENT_SECRET = '<secret>'
    $env:BDR_SECRET_ServiceBusAppSecret = '<secret>'
    ./Invoke-DatabaseRefresh.ps1 -FinOpsUrl https://contoso-uat.sandbox.operations.dynamics.com `
        -TenantId <tenant id> -ClientId <client id> -EnvironmentId UAT -SecretNames ServiceBusAppSecret
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $FinOpsUrl,
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ClientId,
    # Client secret of the application; defaults to the environment variable BDR_CLIENT_SECRET.
    [string] $ClientSecret = $env:BDR_CLIENT_SECRET,
    # Environment code in Database refresh > Setup > Environments; empty for the current instance.
    [string] $EnvironmentId = '',
    # Tasks to run; empty for all active tasks of the environment.
    [string[]] $TaskTypeNames = @(),
    # Names of the secrets the setup refers to. The value of each comes from BDR_SECRET_<name>.
    [string[]] $SecretNames = @(),
    # ID of this run, for example the pipeline run ID. A retry with the same ID returns the first job.
    [string] $RequestId = [guid]::NewGuid().ToString(),
    # How long to wait for the environment to answer after a copy.
    [int] $WaitForEnvironmentMinutes = 60,
    # How long to wait for a job that continues in batch.
    [int] $JobTimeoutMinutes = 240,
    [int] $PollSeconds = 30
)

$ErrorActionPreference = 'Stop'
$FinOpsUrl = $FinOpsUrl.TrimEnd('/')
$api = "$FinOpsUrl/api/services/BDRServices/BDRService"

if (-not $ClientSecret) { throw 'No client secret: pass -ClientSecret or set BDR_CLIENT_SECRET.' }

function Get-Token {
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "$FinOpsUrl/.default"
        grant_type    = 'client_credentials'
    }
    (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body).access_token
}

function Invoke-Bdr([string] $operation, [hashtable] $request) {
    $json = @{ _request = $request } | ConvertTo-Json -Depth 5 -Compress
    $headers = @{ Authorization = "Bearer $script:token" }
    try {
        Invoke-RestMethod -Method Post -Uri "$api/$operation" -Headers $headers -ContentType 'application/json' -Body $json
    }
    catch {
        # The service reports a refused or failed request as HTTP 500 with the reason in the body.
        $detail = $_.ErrorDetails.Message
        if (-not $detail) { $detail = $_.Exception.Message }
        try { $detail = ($detail | ConvertFrom-Json).Message -replace '^An exception occured when invoking the operation - ', '' } catch { }
        throw "BDRService/$operation failed: $detail"
    }
}

function Write-Job($job) {
    Write-Host ("Job {0}, environment {1}: {2}{3}" -f $job.JobId, $job.EnvironmentId, $job.Status, $(if ($job.Message) { " ($($job.Message))" }))
    foreach ($task in $job.Tasks) {
        Write-Host ("  {0,-18} {1,-16} records {2,6}  {3}" -f $task.TaskTypeName, $task.Status, $task.RecordsAffected, $task.Message)
    }
}

# 1 + 2. Token, then wait until Finance and Operations answers.
$deadline = (Get-Date).AddMinutes($WaitForEnvironmentMinutes)
while ($true) {
    try {
        $script:token = Get-Token
        Invoke-RestMethod -Method Get -Uri $api -Headers @{ Authorization = "Bearer $script:token" } | Out-Null
        break
    }
    catch {
        if ((Get-Date) -gt $deadline) { throw "The environment did not answer within $WaitForEnvironmentMinutes minutes: $($_.Exception.Message)" }
        Write-Host "Waiting for $FinOpsUrl ($($_.Exception.Message))"
        Start-Sleep -Seconds $PollSeconds
    }
}

# 3. Run.
$secrets = @(foreach ($name in $SecretNames) {
    $value = [Environment]::GetEnvironmentVariable("BDR_SECRET_$name")
    if (-not $value) { throw "Secret $name is named but the environment variable BDR_SECRET_$name is empty." }
    @{ Name = $name; Value = $value }
})
$request = @{
    EnvironmentId         = $EnvironmentId
    TaskTypeNames         = @($TaskTypeNames)
    RequestId             = $RequestId
    RunInBatch            = $false
    ReturnResultOnFailure = $true
    Secrets               = $secrets
}
Write-Host "Running Database refresh for '$EnvironmentId' (request $RequestId)"
$job = Invoke-Bdr 'run' $request

# 4. A job with data cleanup continues in batch: poll until it is finished.
$deadline = (Get-Date).AddMinutes($JobTimeoutMinutes)
while (-not $job.Finished) {
    Write-Job $job
    if ((Get-Date) -gt $deadline) { throw "Job $($job.JobId) did not finish within $JobTimeoutMinutes minutes." }
    Start-Sleep -Seconds $PollSeconds
    $script:token = Get-Token
    $job = Invoke-Bdr 'getJobStatus' @{ JobId = $job.JobId }
}

# 5. Result.
Write-Job $job
if (-not $job.Succeeded) {
    Write-Host "##vso[task.logissue type=error]Database refresh job $($job.JobId) ended with status $($job.Status)."
    exit 1
}
