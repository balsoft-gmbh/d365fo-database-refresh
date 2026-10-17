<#
.SYNOPSIS
    Creates the two deployable packages of a release from the X++ compiler output.

.DESCRIPTION
    <Name>-LCS.zip is the deployable package for Lifecycle Services environments. The folder <Name>-Unified
    holds the Power Platform unified package for unified environments; deploy its TemplatePackage.dll
    with pac package deploy.

    Runs in Windows PowerShell 5.1, because the packaging libraries target .NET Framework.

.PARAMETER ToolsPath
    The extracted Microsoft.Dynamics.AX.Platform.CompilerPackage.

.PARAMETER BinariesPath
    The compiler output: one folder per X++ package, each with a bin folder.

.PARAMETER CloudRuntimePath
    The libraries that build the unified package.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ToolsPath,
    [Parameter(Mandatory)] [string] $BinariesPath,
    [Parameter(Mandatory)] [string] $CloudRuntimePath,
    [Parameter(Mandatory)] [string] $OutputPath,
    [Parameter(Mandatory)] [string] $Name,
    [string] $PlatformVersion = '7.0.0.0',
    [string] $ApplicationVersion = '10.0.0.0'
)

$ErrorActionPreference = 'Stop'

$packages = @(Get-ChildItem -Path $BinariesPath -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "bin\Dynamics.AX.$($_.Name).dll") })
if (-not $packages) {
    throw "No X++ package with binaries found in $BinariesPath"
}

$work = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$runtimePackages = Join-Path $work 'runtime'
$unifiedInput = Join-Path $work 'unified'
New-Item -ItemType Directory -Force -Path $runtimePackages, $unifiedInput, $OutputPath | Out-Null

try {
    # One runtime package per X++ package, versioned like its assembly.
    Import-Module (Join-Path $ToolsPath 'CreatePackage.psm1')
    foreach ($package in $packages) {
        $assembly = Join-Path $package.FullName "bin\Dynamics.AX.$($package.Name).dll"
        $version = (Get-Item $assembly).VersionInfo.FileVersion
        if (-not $version) {
            $version = '1.0.0.0'
        }
        Write-Host "Runtime package $($package.Name) $version"
        New-XppRuntimePackage -packageName $package.Name -packageDrop $package.FullName -outputDir $runtimePackages `
            -metadataDir $BinariesPath -packageVersion $version -binDir $ToolsPath -enforceVersionCheck $true
    }

    # Lifecycle Services: the runtime packages merged into the base deployable package of the compiler package.
    Add-Type -Path (Join-Path $ToolsPath 'Microsoft.Dynamics.AXCreateDeployablePackageBase.dll')
    $combined = Join-Path $work 'combined.zip'
    $lcsPackage = Join-Path $OutputPath "$Name-LCS.zip"
    [Microsoft.Dynamics.AXCreateDeployablePackageBase.BuildDeployablePackages]::CreateMetadataPackage($runtimePackages, $combined)
    [Microsoft.Dynamics.AXCreateDeployablePackageBase.BuildDeployablePackages]::MergePackage(
        (Join-Path $ToolsPath 'BaseMetadataDeployablePackage.zip'), $combined, $lcsPackage, $true, [string]::Empty)
    Write-Host "Created $lcsPackage"

    # Unified: every runtime package (dynamicsax-<package>.<version>.zip) expanded into a folder named after the package.
    foreach ($zip in Get-ChildItem -Path (Join-Path $runtimePackages 'files') -Filter *.zip) {
        $folder = $zip.BaseName -replace '^dynamicsax-', '' -replace '\.\d+\.\d+\.\d+\.\d+$', ''
        Expand-Archive -Path $zip.FullName -DestinationPath (Join-Path $unifiedInput $folder)
    }

    # The libraries depend on each other; load them in this order.
    $libraries = 'System.Text.Encodings.Web', 'System.Threading.Tasks.Extensions', 'System.Memory', 'Microsoft.Bcl.AsyncInterfaces',
        'System.Text.Json', 'Microsoft.Xrm.Sdk', 'Microsoft.IdentityModel.Clients.ActiveDirectory',
        'Microsoft.Xrm.Tooling.PackageDeployment.CrmPackageExtentionBase', 'Microsoft.Xrm.Tooling.PackageDeployment.CrmPackageCore.FinanceOperations',
        'Microsoft.Xrm.Tooling.PackageDeployment.CrmPackageCore', 'Microsoft.Dynamics.VSExtension.Shared', 'Microsoft.ApplicationInsights',
        'Microsoft.PowerPlatform.VSShared.Util', 'Microsoft.Xrm.Tooling.Connector', 'Newtonsoft.Json', 'Microsoft.Dynamics.AX.DesignTime.Telemetry2'
    foreach ($library in $libraries) {
        try {
            Add-Type -Path (Join-Path $CloudRuntimePath "$library.dll")
        }
        catch {
            # The assembly is loaded even then; only types that need assemblies outside this set are missing.
            if ($_.FullyQualifiedErrorId -notlike 'System.Reflection.ReflectionTypeLoadException*') {
                throw
            }
            $missing = @($_.Exception.LoaderExceptions | ForEach-Object { $_.Message } | Select-Object -Unique -First 3)
            Write-Host "$library loaded without some of its types: $($missing -join ' | ')"
        }
    }

    $unifiedBuilder = @"
using System;
using Microsoft.PowerPlatform.VSShared.Util;

public static class UnifiedPackageBuilder
{
    public static string Create(string buildOutput, string platformVersion, string applicationVersion)
    {
        return new PipelineOperation()
            .PerformCreatePackageOperation(buildOutput, platformVersion, applicationVersion, Guid.Empty.ToString())
            .GetAwaiter().GetResult();
    }
}
"@
    Add-Type -ReferencedAssemblies 'System', (Join-Path $CloudRuntimePath 'Microsoft.PowerPlatform.VSShared.Util.dll') `
        -TypeDefinition $unifiedBuilder -Language CSharp

    # The unified package library writes zip files; .NET Framework writes backslashes in them unless this switch is off.
    [AppContext]::SetSwitch('Switch.System.IO.Compression.ZipFile.UseBackslash', $false)
    $unifiedFolder = [UnifiedPackageBuilder]::Create($unifiedInput, $PlatformVersion, $ApplicationVersion)
    if (-not (Test-Path (Join-Path $unifiedFolder 'TemplatePackage.dll'))) {
        throw "TemplatePackage.dll not found in $unifiedFolder"
    }

    # The workflow zips this folder in PowerShell 7, which always writes forward slashes.
    $unifiedPackage = Join-Path $OutputPath "$Name-Unified"
    Copy-Item -Path $unifiedFolder -Destination $unifiedPackage -Recurse
    Write-Host "Created $unifiedPackage"
}
finally {
    Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
}
