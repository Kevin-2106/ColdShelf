#requires -Version 7.4

[CmdletBinding()]
param(
    [string]$InstallRoot = $PSScriptRoot,
    [switch]$NoBroadcast
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if (-not [string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)) {
        $full = $full.TrimEnd([char[]]@('\', '/'))
    }
    return $full
}

function Test-EquivalentPathEntry {
    param(
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][string]$ExpectedPath
    )

    $candidate = $Entry.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        return [string]::Equals((Get-NormalizedPath $expanded), (Get-NormalizedPath $ExpectedPath), [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Remove-OwnedPathEntry {
    param(
        [AllowNull()][string]$PathValue,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    $value = [string]$PathValue
    $matches = [Collections.Generic.List[object]]::new()
    $start = 0
    while ($start -le $value.Length) {
        $separator = $value.IndexOf(';', $start)
        $end = if ($separator -ge 0) { $separator } else { $value.Length }
        $entry = $value.Substring($start, $end - $start)
        if (Test-EquivalentPathEntry -Entry $entry -ExpectedPath $InstallRoot) {
            $matches.Add([pscustomobject]@{ Start = $start; End = $end })
        }
        if ($separator -lt 0) { break }
        $start = $separator + 1
    }

    if ($matches.Count -eq 0) {
        return [pscustomobject]@{ Success = $true; Changed = $false; Value = $value }
    }
    if ($matches.Count -ne 1) {
        return [pscustomobject]@{ Success = $false; Changed = $false; Value = $value; Error = 'The owned PATH entry is not unique.' }
    }

    $match = $matches[0]
    if ($match.End -lt $value.Length) {
        $removeStart = $match.Start
        $removeLength = ($match.End - $match.Start) + 1
    }
    elseif ($match.Start -gt 0) {
        $removeStart = $match.Start - 1
        $removeLength = $match.End - $removeStart
    }
    else {
        $removeStart = 0
        $removeLength = $match.End
    }

    return [pscustomobject]@{
        Success = $true
        Changed = $true
        Value = $value.Remove($removeStart, $removeLength)
    }
}

function Get-RequiredStateProperty {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Name
    )

    if ($State.PSObject.Properties.Name -notcontains $Name) {
        throw "Installation state is missing required property: $Name"
    }
    return $State.$Name
}

function Get-StringHash {
    param([AllowNull()][string]$Value)

    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Value)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Assert-StateStringHash {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$ValueProperty,
        [Parameter(Mandatory)][string]$HashProperty
    )

    $value = [string](Get-RequiredStateProperty -State $State -Name $ValueProperty)
    $expected = [string](Get-RequiredStateProperty -State $State -Name $HashProperty)
    if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or
        -not [string]::Equals((Get-StringHash $value), $expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Installation state failed its $ValueProperty integrity check."
    }
}

function Send-EnvironmentChanged {
    param([Parameter(Mandatory)][string]$RegistrySubKey)

    if ($NoBroadcast -or -not [string]::Equals($RegistrySubKey, 'Environment', [StringComparison]::OrdinalIgnoreCase)) { return }
    if (-not ('ColdShelf.NativeMethods' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace ColdShelf {
    public static class NativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
            uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
    }
}
'@
    }
    [UIntPtr]$result = [UIntPtr]::Zero
    [void][ColdShelf.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result)
}

function Start-FileCleanup {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$FileNames,
        [Parameter(Mandatory)][int]$ParentPid
    )

    $directoryLiteral = $Directory.Replace("'", "''")
    $fileLiterals = @($FileNames | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '
    $command = @"
`$ErrorActionPreference = 'SilentlyContinue'
while (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 100 }
`$path = [IO.Path]::GetFullPath('$directoryLiteral')
foreach (`$name in @($fileLiterals)) {
    if ([IO.Path]::GetFileName(`$name) -ne `$name) { continue }
    `$file = Join-Path `$path `$name
    if ([IO.File]::Exists(`$file)) { [IO.File]::SetAttributes(`$file, [IO.FileAttributes]::Normal); [IO.File]::Delete(`$file) }
}
if ([IO.Directory]::Exists(`$path) -and @(Get-ChildItem -LiteralPath `$path -Force).Count -eq 0) {
    [IO.Directory]::Delete(`$path, `$false)
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WindowStyle Hidden -PassThru
}

$installRoot = Get-NormalizedPath $InstallRoot
if ([string]::Equals($installRoot, [IO.Path]::GetPathRoot($installRoot), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to uninstall from a filesystem root.'
}
if (-not (Test-Path -LiteralPath $installRoot)) {
    Write-Host "ColdShelf is already uninstalled from: $installRoot"
    return
}
$statePath = Join-Path $installRoot 'install-state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "Installation state is missing; PATH ownership cannot be established: $statePath"
}
try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json }
catch { throw "Installation state is unreadable; refusing to change PATH or delete files: $statePath" }

if ([int](Get-RequiredStateProperty -State $state -Name 'version') -ne 2) { throw 'Unsupported installation state version. Reinstall ColdShelf before uninstalling.' }
if (-not [string]::Equals([string](Get-RequiredStateProperty -State $state -Name 'product'), 'ColdShelf', [StringComparison]::Ordinal) -or
    -not [string]::Equals([string](Get-RequiredStateProperty -State $state -Name 'fileOwnership'), 'managed-files-v1', [StringComparison]::Ordinal)) {
    throw 'Installation state has an invalid ownership contract.'
}
if (-not [string]::Equals((Get-NormalizedPath ([string](Get-RequiredStateProperty -State $state -Name 'installRoot'))), $installRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installation state does not belong to this directory.'
}
$expectedManagedFiles = @('coldshelf.ps1', 'coldshelf.cmd', 'uninstall.ps1', 'install-state.json')
$managedFiles = @((Get-RequiredStateProperty -State $state -Name 'managedFiles') | ForEach-Object { [string]$_ })
if ($managedFiles.Count -ne $expectedManagedFiles.Count -or
    (@($managedFiles | Sort-Object) -join '|') -cne (@($expectedManagedFiles | Sort-Object) -join '|')) {
    throw 'Installation state contains an invalid managed file set.'
}
$unexpected = @(Get-ChildItem -LiteralPath $installRoot -Force | Where-Object { $_.Name -notin $managedFiles })
if ($unexpected.Count -gt 0) {
    throw "InstallRoot contains files not owned by ColdShelf; refusing to uninstall: $($unexpected[0].FullName)"
}
$invalidManagedEntry = @(Get-ChildItem -LiteralPath $installRoot -Force | Where-Object {
    $_.Name -in $managedFiles -and ($_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
} | Select-Object -First 1)
if ($invalidManagedEntry.Count -gt 0) {
    throw "InstallRoot contains an invalid managed file entry; refusing to uninstall: $($invalidManagedEntry[0].FullName)"
}
foreach ($booleanProperty in @('pathOwned', 'pathBeforeExisted')) {
    if ((Get-RequiredStateProperty -State $state -Name $booleanProperty) -isnot [bool]) {
        throw "Installation state property must be Boolean: $booleanProperty"
    }
}
foreach ($property in @('pathBefore', 'pathBeforeKind', 'pathAfter', 'installedAt')) {
    [void](Get-RequiredStateProperty -State $state -Name $property)
}
Assert-StateStringHash -State $state -ValueProperty 'pathBefore' -HashProperty 'pathBeforeSha256'
Assert-StateStringHash -State $state -ValueProperty 'pathAfter' -HashProperty 'pathAfterSha256'
$registrySubKey = [string](Get-RequiredStateProperty -State $state -Name 'registrySubKey')
if ([string]::IsNullOrWhiteSpace($registrySubKey)) { throw 'Installation state does not identify the user environment registry key.' }

$key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registrySubKey, $true)
if ($null -eq $key) { throw "Could not open HKCU\$registrySubKey for writing." }
$pathChanged = $false
try {
    $valueNames = @($key.GetValueNames())
    $pathExists = $valueNames -contains 'Path'
    $currentPath = if ($pathExists) { [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { '' }
    $currentKind = if ($pathExists) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }

    if ([bool]$state.pathOwned) {
        if ([string]::Equals($currentPath, [string]$state.pathAfter, [StringComparison]::Ordinal)) {
            if ([bool]$state.pathBeforeExisted) {
                $beforeKind = [Microsoft.Win32.RegistryValueKind]([Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$state.pathBeforeKind))
                $key.SetValue('Path', [string]$state.pathBefore, $beforeKind)
            }
            elseif ($pathExists) {
                $key.DeleteValue('Path', $false)
            }
            $pathChanged = $true
        }
        else {
            $removal = Remove-OwnedPathEntry -PathValue $currentPath -InstallRoot $installRoot
            if (-not $removal.Success) {
                throw "Cannot remove the ColdShelf PATH entry safely: $($removal.Error) Installation files were preserved."
            }
            if ($removal.Changed) {
                $key.SetValue('Path', [string]$removal.Value, $currentKind)
                $pathChanged = $true
            }
        }
    }
}
finally {
    $key.Dispose()
}

if ($pathChanged) { Send-EnvironmentChanged -RegistrySubKey $registrySubKey }
$cleanup = Start-FileCleanup -Directory $installRoot -FileNames $managedFiles -ParentPid $PID
Write-Host "ColdShelf-managed command files are scheduled for removal from: $installRoot"
Write-Host 'ColdShelf state, archives, and restored data were not removed.'
if ($pathChanged) { Write-Host 'The user PATH was updated. Open a new terminal to observe the change.' }
