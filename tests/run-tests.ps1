#requires -Version 7.4

[CmdletBinding()]
param(
    [string]$CliPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'coldshelf.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:LastCommand = $null

function Write-TestLine {
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Message
    )

    Write-Host ('[{0}] {1}' -f $State, $Message)
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()]$Actual,
        [AllowNull()]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Actual -ne $Expected) {
        throw ('{0} (expected: {1}; actual: {2})' -f $Message, $Expected, $Actual)
    }
}

function Assert-Matches {
    param(
        [AllowEmptyString()][string]$Actual,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Actual -notmatch $Pattern) {
        throw ('{0} (pattern: {1}; actual: {2})' -f $Message, $Pattern, $Actual)
    }
}

function Format-CommandResult {
    param([Parameter(Mandatory)]$Result)

    @"
command: pwsh -File "$CliPath" $($Result.Arguments -join ' ')
exit code: $($Result.ExitCode)
timed out: $($Result.TimedOut)
stdout:
$($Result.StdOut)
stderr:
$($Result.StdErr)
"@
}

function Assert-Succeeded {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Result.TimedOut -or $Result.ExitCode -ne 0) {
        throw ("$Message`n$(Format-CommandResult $Result)")
    }
}

function Assert-Failed {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Result.TimedOut -or $Result.ExitCode -eq 0) {
        throw ("$Message`n$(Format-CommandResult $Result)")
    }
}

function Assert-ExitCode {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][int]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Result.TimedOut -or $Result.ExitCode -ne $Expected) {
        throw ("$Message`n$(Format-CommandResult $Result)")
    }
}

function Invoke-TestCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    try {
        $null = & $Body
        $script:Passed++
        Write-TestLine -State 'PASS' -Message $Name
    }
    catch {
        $script:Failed++
        $detail = $_.Exception.Message
        $script:Failures.Add("${Name}: $detail")
        Write-TestLine -State 'FAIL' -Message $Name
        Write-Host $detail
    }
}

function Test-IsUnderRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Remove-TestOwnedPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    if (-not (Test-IsUnderRoot -Path $Path -Root $Root)) {
        throw "Refusing to remove path outside the test root: $Path"
    }

    if (Test-Path -LiteralPath $Path) {
        Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.Attributes = [IO.FileAttributes]::Normal } catch { }
        }
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Invoke-ColdShelf {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 60
    )

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:PwshPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $script:WorkRoot

    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $CliPath) + $Arguments) {
        [void]$psi.ArgumentList.Add([string]$argument)
    }

    $psi.Environment['COLDSHELF_HOME'] = $script:ColdShelfHome
    $psi.Environment['COLDSHELF_TEST_ROOT'] = $script:TestRoot
    $psi.Environment['COLDSHELF_TEST_TOKEN'] = $script:OwnershipToken
    $psi.Environment['NO_COLOR'] = '1'
    [void]$psi.Environment.Remove('COLDSHELF_TAR_PATH')
    foreach ($key in $Environment.Keys) {
        $psi.Environment[[string]$key] = [string]$Environment[$key]
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) {
        throw 'Failed to start child pwsh process.'
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $process.Kill($true) } catch { }
        $process.WaitForExit()
    }

    $result = [pscustomobject]@{
        Arguments = @($Arguments)
        ExitCode = if ($finished) { $process.ExitCode } else { -1 }
        TimedOut = -not $finished
        StdOut = $stdoutTask.GetAwaiter().GetResult()
        StdErr = $stderrTask.GetAwaiter().GetResult()
    }
    $process.Dispose()
    $script:LastCommand = $result
    return $result
}

function Invoke-ColdShelfFromLocation {
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$ColdShelfHome,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60
    )

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:PwshPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $env:USERPROFILE
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Set-Location -LiteralPath $env:COLDSHELF_TEST_LOCATION; $invokeArguments = @($env:COLDSHELF_TEST_ARGUMENTS_JSON | ConvertFrom-Json); & $env:COLDSHELF_TEST_CLI @invokeArguments; exit $LASTEXITCODE')) {
        [void]$psi.ArgumentList.Add([string]$argument)
    }
    $psi.Environment['COLDSHELF_HOME'] = $ColdShelfHome
    $psi.Environment['COLDSHELF_TEST_LOCATION'] = $Location
    $psi.Environment['COLDSHELF_TEST_CLI'] = $CliPath
    $psi.Environment['COLDSHELF_TEST_ARGUMENTS_JSON'] = ConvertTo-Json -InputObject @($Arguments) -Compress
    $psi.Environment['NO_COLOR'] = '1'

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw 'Failed to start location-aware child pwsh process.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $process.Kill($true) } catch { }
        $process.WaitForExit()
    }
    $result = [pscustomobject]@{
        Arguments = @($Arguments)
        ExitCode = if ($finished) { $process.ExitCode } else { -1 }
        TimedOut = -not $finished
        StdOut = $stdoutTask.GetAwaiter().GetResult()
        StdErr = $stderrTask.GetAwaiter().GetResult()
    }
    $process.Dispose()
    return $result
}

function New-TestDataset {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Marker = 'dataset'
    )

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Path 'empty directory 空') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Path '子目录 with spaces') -Force | Out-Null

    $deep = $Path
    foreach ($segment in @('deep-01', '深层-02', 'deep 03', 'δ-04', 'deep-05', '终点-06')) {
        $deep = Join-Path $deep $segment
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
    }

    [IO.File]::WriteAllText((Join-Path $Path 'plain.txt'), "plain-$Marker`nline-two", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Path 'file with spaces.txt'), "spaces-$Marker", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Path '中文文件.txt'), "中文内容-$Marker", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Path 'unicode-😀-é-δ.txt'), "Unicode 😀 café Δ $Marker", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Path '.dotfile'), "dot-$Marker", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Path '.隐藏-dotfile'), "hidden-dot-$Marker", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Path '子目录 with spaces\nested 中文.txt'), "nested-$Marker", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes((Join-Path $deep 'binary.bin'), [byte[]](0, 1, 2, 3, 127, 128, 254, 255))

    $readOnlyPath = Join-Path $Path 'read only 文件.txt'
    [IO.File]::WriteAllText($readOnlyPath, "readonly-$Marker", [Text.UTF8Encoding]::new($false))
    [IO.File]::SetAttributes($readOnlyPath, [IO.FileAttributes]::ReadOnly)

    $hiddenPath = Join-Path $Path 'hidden-file.txt'
    [IO.File]::WriteAllText($hiddenPath, "hidden-$Marker", [Text.UTF8Encoding]::new($false))
    [IO.File]::SetAttributes($hiddenPath, [IO.FileAttributes]::Hidden)
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    $root = [IO.Path]::GetFullPath($Path)
    $entries = foreach ($item in Get-ChildItem -LiteralPath $root -Force -Recurse | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($root, $item.FullName).Replace('\', '/')
        if ($item.PSIsContainer) {
            [pscustomobject]@{ Path = $relative; Type = 'directory'; Length = $null; Hash = $null }
        }
        else {
            [pscustomobject]@{
                Path = $relative
                Type = 'file'
                Length = $item.Length
                Hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            }
        }
    }
    return ($entries | ConvertTo-Json -Depth 4 -Compress)
}

function Set-TarTextField {
    param(
        [Parameter(Mandatory)][byte[]]$Block,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][int]$Length,
        [Parameter(Mandatory)][string]$Value
    )

    $bytes = [Text.Encoding]::ASCII.GetBytes($Value)
    if ($bytes.Length -gt $Length) { throw "TAR fixture field exceeds $Length bytes: $Value" }
    [Array]::Copy($bytes, 0, $Block, $Offset, $bytes.Length)
}

function New-UstarHeader {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][char]$TypeFlag,
        [Parameter(Mandatory)][long]$Size
    )

    $block = [byte[]]::new(512)
    Set-TarTextField -Block $block -Offset 0 -Length 100 -Value $Name
    Set-TarTextField -Block $block -Offset 100 -Length 8 -Value "0000755`0"
    Set-TarTextField -Block $block -Offset 108 -Length 8 -Value "0000000`0"
    Set-TarTextField -Block $block -Offset 116 -Length 8 -Value "0000000`0"
    Set-TarTextField -Block $block -Offset 124 -Length 12 -Value (([Convert]::ToString($Size, 8)).PadLeft(11, '0') + "`0")
    Set-TarTextField -Block $block -Offset 136 -Length 12 -Value "00000000000`0"
    for ($index = 148; $index -lt 156; $index++) { $block[$index] = 32 }
    $block[156] = [byte][char]$TypeFlag
    Set-TarTextField -Block $block -Offset 257 -Length 6 -Value "ustar`0"
    Set-TarTextField -Block $block -Offset 263 -Length 2 -Value '00'

    [long]$checksum = 0
    foreach ($value in $block) { $checksum += $value }
    Set-TarTextField -Block $block -Offset 148 -Length 8 -Value (([Convert]::ToString($checksum, 8)).PadLeft(6, '0') + "`0 ")
    return $block
}

function Write-PaxSizeTarFixture {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$PaxSize
    )

    $content = [Text.Encoding]::ASCII.GetBytes('hello')
    $payloadWithoutLength = " size=$PaxSize`n"
    $recordLength = $payloadWithoutLength.Length + 2
    while (("$recordLength$payloadWithoutLength").Length -ne $recordLength) {
        $recordLength = ("$recordLength$payloadWithoutLength").Length
    }
    $paxData = [Text.Encoding]::UTF8.GetBytes("$recordLength$payloadWithoutLength")
    $stream = [IO.File]::Create($Path)
    try {
        $directoryHeader = New-UstarHeader -Name 'paxsize/' -TypeFlag '5' -Size 0
        $stream.Write($directoryHeader, 0, $directoryHeader.Length)
        $paxHeader = New-UstarHeader -Name 'paxsize/PaxHeader/file.bin' -TypeFlag 'x' -Size $paxData.Length
        $stream.Write($paxHeader, 0, $paxHeader.Length)
        $stream.Write($paxData, 0, $paxData.Length)
        $paxPadding = [byte[]]::new(512 - $paxData.Length)
        $stream.Write($paxPadding, 0, $paxPadding.Length)
        $fileHeader = New-UstarHeader -Name 'paxsize/file.bin' -TypeFlag '0' -Size $content.Length
        $stream.Write($fileHeader, 0, $fileHeader.Length)
        $stream.Write($content, 0, $content.Length)
        $contentPadding = [byte[]]::new(512 - $content.Length)
        $stream.Write($contentPadding, 0, $contentPadding.Length)
        $endBlocks = [byte[]]::new(1024)
        $stream.Write($endBlocks, 0, $endBlocks.Length)
    }
    finally {
        $stream.Dispose()
    }
}

function Publish-PaxSizeFixture {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][long]$PaxSize
    )

    $directory = Join-Path (Join-Path $script:ArchiveRoot 'archives') $Id
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    try {
        $archivePath = Join-Path $directory 'archive.tar'
        Write-PaxSizeTarFixture -Path $archivePath -PaxSize $PaxSize
        $contentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes('hello'))).ToLowerInvariant()
        $manifest = [ordered]@{
            version = 1
            entries = @([ordered]@{ path = 'file.bin'; type = 'file'; length = 5; sha256 = $contentHash })
        }
        [IO.File]::WriteAllText((Join-Path $directory 'manifest.json'), (($manifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $metadata = [ordered]@{
            version = 1; id = $Id; name = 'paxsize'; sourcePath = (Join-Path $script:TestRoot 'paxsize')
            archiveFile = 'archive.tar'; manifestFile = 'manifest.json'; createdAt = [DateTimeOffset]::Now.ToString('o')
            originalSize = 5; fileCount = 1; directoryCount = 1; archiveSize = (Get-Item -LiteralPath $archivePath).Length
            status = 'cold'; sourceRemoved = $false; archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        [IO.File]::WriteAllText((Join-Path $directory 'meta.json'), (($metadata | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        return $directory
    }
    catch {
        Remove-TestOwnedPath -Path $directory -Root $script:TestRoot
        throw
    }
}

function Publish-LinkArchiveFixture {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$LinkTarget
    )

    $directory = Join-Path (Join-Path $script:ArchiveRoot 'archives') $Id
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    try {
        $archivePath = Join-Path $directory 'archive.tar'
        $stream = [IO.File]::Create($archivePath)
        try {
            $writer = [System.Formats.Tar.TarWriter]::new($stream, [System.Formats.Tar.TarEntryFormat]::Pax, $true)
            try {
                $rootEntry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::Directory, 'linkfixture/')
                $writer.WriteEntry($rootEntry)
                $linkEntry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::SymbolicLink, 'linkfixture/escape-link')
                $linkEntry.LinkName = $LinkTarget
                $writer.WriteEntry($linkEntry)
            }
            finally { $writer.Dispose() }
        }
        finally { $stream.Dispose() }

        $manifest = [ordered]@{ version = 1; entries = @() }
        [IO.File]::WriteAllText((Join-Path $directory 'manifest.json'), (($manifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $metadata = [ordered]@{
            version = 1; id = $Id; name = 'linkfixture'; sourcePath = $TargetPath
            archiveFile = 'archive.tar'; manifestFile = 'manifest.json'; createdAt = [DateTimeOffset]::Now.ToString('o')
            originalSize = 0; fileCount = 0; directoryCount = 1; archiveSize = (Get-Item -LiteralPath $archivePath).Length
            status = 'cold'; sourceRemoved = $true; archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        [IO.File]::WriteAllText((Join-Path $directory 'meta.json'), (($metadata | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        return $directory
    }
    catch {
        Remove-TestOwnedPath -Path $directory -Root $script:TestRoot
        throw
    }
}

function Get-ArchiveRecords {
    $archivesPath = Join-Path $script:ArchiveRoot 'archives'
    if (-not (Test-Path -LiteralPath $archivesPath -PathType Container)) {
        return @()
    }

    $records = foreach ($directory in Get-ChildItem -LiteralPath $archivesPath -Directory -Force) {
        if ($directory.Name.EndsWith('.tmp', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $metaPath = Join-Path $directory.FullName 'meta.json'
        if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
            continue
        }

        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        }
        catch {
            continue
        }

        [pscustomobject]@{
            Id = $directory.Name
            Directory = $directory.FullName
            MetaPath = $metaPath
            Meta = $meta
        }
    }
    return @($records)
}

function Invoke-ColdAndGetArchive {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][ValidateSet('--keep', '--remove')][string]$Mode,
        [hashtable]$Environment = @{}
    )

    $beforeIds = @(Get-ArchiveRecords | ForEach-Object Id)
    $result = Invoke-ColdShelf -Arguments @('cold', $SourcePath, $Mode) -Environment $Environment
    Assert-Succeeded -Result $result -Message "cold $Mode should succeed for $SourcePath"
    $newRecords = @(Get-ArchiveRecords | Where-Object { $_.Id -notin $beforeIds })
    Assert-Equal -Actual $newRecords.Count -Expected 1 -Message 'cold should publish exactly one new archive'
    return $newRecords[0]
}

function Get-DefenderSessionDirectories {
    $sessionRoot = Join-Path $script:ColdShelfHome 'defender-sessions'
    if (-not (Test-Path -LiteralPath $sessionRoot -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $sessionRoot -Directory -Force | Sort-Object Name)
}

function Get-NewDefenderSession {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$BeforePaths)

    $sessions = @(Get-DefenderSessionDirectories | Where-Object { $_.FullName -notin $BeforePaths })
    Assert-Equal -Actual $sessions.Count -Expected 1 -Message 'hot -d should create exactly one Defender session'
    return $sessions[0]
}

function Read-RequiredJson {
    param([Parameter(Mandatory)][string]$Path)

    Assert-True -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message "required JSON file is missing: $Path"
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Assert-PathArraysEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    $actualPaths = @($Actual | ForEach-Object { [IO.Path]::GetFullPath([string]$_) })
    $expectedPaths = @($Expected | ForEach-Object { [IO.Path]::GetFullPath([string]$_) })
    Assert-Equal -Actual $actualPaths.Count -Expected $expectedPaths.Count -Message "$Message count is incorrect"
    for ($index = 0; $index -lt $expectedPaths.Count; $index++) {
        Assert-Equal -Actual $actualPaths[$index] -Expected $expectedPaths[$index] -Message "$Message differs at index $index"
    }
}

function Assert-NoRestoreStaging {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$ArchiveId
    )

    $parent = Split-Path -Path $Target -Parent
    $staging = @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith(".coldshelf-restore-$ArchiveId-", [StringComparison]::OrdinalIgnoreCase) })
    Assert-Equal -Actual $staging.Count -Expected 0 -Message 'restore staging directory should be cleaned up'
}

$resolvedCli = [IO.Path]::GetFullPath($CliPath)
$CliPath = $resolvedCli
$pwshCommand = Get-Command pwsh -ErrorAction Stop
$script:PwshPath = $pwshCommand.Source

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$uniqueName = 'ColdShelf-tests-{0}' -f [Guid]::NewGuid().ToString('N')
$script:TestRoot = Join-Path $tempBase $uniqueName
$script:ColdShelfHome = Join-Path $script:TestRoot 'state home'
$script:ArchiveRoot = Join-Path $script:TestRoot 'archive root 中文'
$script:WorkRoot = Join-Path $script:TestRoot 'working directory'
$script:OwnershipToken = [Guid]::NewGuid().ToString('N')
$ownershipToken = $script:OwnershipToken
$ownershipMarker = Join-Path $script:TestRoot '.coldshelf-test-owner'

New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
New-Item -ItemType Directory -Path $script:WorkRoot -Force | Out-Null
[IO.File]::WriteAllText($ownershipMarker, $ownershipToken, [Text.UTF8Encoding]::new($false))

try {
    if (-not (Test-Path -LiteralPath $CliPath -PathType Leaf)) {
        throw "ColdShelf CLI not found: $CliPath"
    }

    Invoke-TestCase 'relative init path resolves from the PowerShell current location' {
        $relativeLocation = Join-Path $script:TestRoot 'relative init location 中文'
        $relativeHome = Join-Path $script:TestRoot 'relative init state'
        New-Item -ItemType Directory -Path $relativeLocation -Force | Out-Null
        $result = Invoke-ColdShelfFromLocation -Location $relativeLocation -ColdShelfHome $relativeHome -Arguments @('init', '.\')
        Assert-Succeeded -Result $result -Message 'init .\ should resolve from the PowerShell current location'
        $config = Get-Content -LiteralPath (Join-Path $relativeHome 'config.json') -Raw | ConvertFrom-Json
        Assert-Equal -Actual ([IO.Path]::GetFullPath([string]$config.archiveRoot)) -Expected ([IO.Path]::GetFullPath($relativeLocation)) -Message 'relative init path resolved from the wrong process directory'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $relativeLocation 'archives') -PathType Container) -Message 'relative init did not create archives under the PowerShell current location'
    }

    Invoke-TestCase 'init creates isolated state and archive layout' {
        $result = Invoke-ColdShelf -Arguments @('init', $script:ArchiveRoot)
        Assert-Succeeded -Result $result -Message 'init should succeed'
        Assert-True -Condition (Test-Path -LiteralPath $script:ColdShelfHome -PathType Container) -Message 'COLDSHELF_HOME was not created'
        Assert-True -Condition (Test-Path -LiteralPath $script:ArchiveRoot -PathType Container) -Message 'archive root was not created'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $script:ColdShelfHome 'config.json') -PathType Leaf) -Message 'config.json was not created'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $script:ArchiveRoot 'archives') -PathType Container) -Message 'archives directory was not created'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $script:ArchiveRoot 'index.json') -PathType Leaf) -Message 'index.json was not created'
    }

    Invoke-TestCase 'init rejects archive roots inside state before creating them' {
        $unsafeArchiveRoot = Join-Path $script:ColdShelfHome 'must not be created archive root'
        Assert-True -Condition (-not (Test-Path -LiteralPath $unsafeArchiveRoot)) -Message 'unsafe archive-root fixture unexpectedly exists'
        $result = Invoke-ColdShelf -Arguments @('init', $unsafeArchiveRoot)
        Assert-ExitCode -Result $result -Expected 5 -Message 'init should reject an archive root inside ColdShelf state'
        Assert-True -Condition (-not (Test-Path -LiteralPath $unsafeArchiveRoot)) -Message 'init created an unsafe archive root before rejecting it'
    }

    Invoke-TestCase 'init rejects protected user root without changing config' {
        $configPath = Join-Path $script:ColdShelfHome 'config.json'
        $configBefore = Get-Content -LiteralPath $configPath -Raw
        $result = Invoke-ColdShelf -Arguments @('init', $env:USERPROFILE)
        Assert-ExitCode -Result $result -Expected 5 -Message 'init should reject USERPROFILE as archiveRoot'
        Assert-Equal -Actual (Get-Content -LiteralPath $configPath -Raw) -Expected $configBefore -Message 'protected-root rejection changed the active config'
    }

    Invoke-TestCase 'ColdShelf state cannot be archived and removed as a source' {
        $configPath = Join-Path $script:ColdShelfHome 'config.json'
        $configBefore = Get-Content -LiteralPath $configPath -Raw
        $result = Invoke-ColdShelf -Arguments @('cold', $script:ColdShelfHome, '--remove')
        Assert-ExitCode -Result $result -Expected 5 -Message 'cold should reject the ColdShelf state directory as a source'
        Assert-True -Condition (Test-Path -LiteralPath $script:ColdShelfHome -PathType Container) -Message 'cold removed the ColdShelf state directory'
        Assert-Equal -Actual (Get-Content -LiteralPath $configPath -Raw) -Expected $configBefore -Message 'cold changed state configuration while rejecting it'
    }

    Invoke-TestCase 'tampered config cannot create a missing archives directory' {
        $configPath = Join-Path $script:ColdShelfHome 'config.json'
        $originalConfig = Get-Content -LiteralPath $configPath -Raw
        $tamperedRoot = Join-Path $script:TestRoot 'tampered configured archive root'
        New-Item -ItemType Directory -Path $tamperedRoot -Force | Out-Null
        $missingArchives = Join-Path $tamperedRoot 'archives'
        try {
            [IO.File]::WriteAllText($configPath, (([ordered]@{ version = 1; archiveRoot = $tamperedRoot } | ConvertTo-Json) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            $result = Invoke-ColdShelf -Arguments @('list')
            Assert-ExitCode -Result $result -Expected 8 -Message 'config load should reject a missing archives directory'
            Assert-True -Condition (-not (Test-Path -LiteralPath $missingArchives)) -Message 'config load created archives before rejecting damaged state'
        }
        finally {
            [IO.File]::WriteAllText($configPath, $originalConfig, [Text.UTF8Encoding]::new($false))
            Remove-TestOwnedPath -Path $tamperedRoot -Root $script:TestRoot
        }
    }

    Invoke-TestCase 'matching PAX size is accepted and fully verified' {
        $id = '20000101-000000-paxok1'
        $directory = Publish-PaxSizeFixture -Id $id -PaxSize 5
        Assert-True -Condition (Test-Path -LiteralPath $directory -PathType Container) -Message 'matching PAX size fixture was not published'
        $verify = Invoke-ColdShelf -Arguments @('verify', $id, '--full')
        Assert-Succeeded -Result $verify -Message 'verify --full should accept a PAX size matching the tar header'
    }

    Invoke-TestCase 'mismatched PAX size fails closed with Integrity exit code 7' {
        $id = '20000101-000000-paxbad'
        $directory = Publish-PaxSizeFixture -Id $id -PaxSize 6
        try {
            $beforeHash = (Get-FileHash -LiteralPath (Join-Path $directory 'archive.tar') -Algorithm SHA256).Hash
            $verify = Invoke-ColdShelf -Arguments @('verify', $id, '--full')
            Assert-ExitCode -Result $verify -Expected 7 -Message 'verify --full should reject a PAX size that differs from the tar header'
            Assert-True -Condition (Test-Path -LiteralPath $directory -PathType Container) -Message 'mismatched PAX size verification removed the archive fixture'
            Assert-Equal -Actual (Get-FileHash -LiteralPath (Join-Path $directory 'archive.tar') -Algorithm SHA256).Hash -Expected $beforeHash -Message 'mismatched PAX size verification changed the archive fixture'
        }
        finally {
            Remove-TestOwnedPath -Path $directory -Root $script:TestRoot
        }
    }

    Invoke-TestCase 'hot rejects symbolic links before native extraction' {
        $id = '20000101-000000-link01'
        $target = Join-Path $script:TestRoot 'linkfixture'
        $sentinel = Join-Path $script:TestRoot 'outside-sentinel.txt'
        [IO.File]::WriteAllText($sentinel, 'must remain unchanged', [Text.UTF8Encoding]::new($false))
        $sentinelHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
        $directory = Publish-LinkArchiveFixture -Id $id -TargetPath $target -LinkTarget $sentinel
        try {
            $hot = Invoke-ColdShelf -Arguments @('hot', $id)
            Assert-ExitCode -Result $hot -Expected 7 -Message 'hot should reject a symbolic-link archive with Integrity exit code'
            Assert-True -Condition (-not (Test-Path -LiteralPath $target)) -Message 'hot published a target from a symbolic-link archive'
            Assert-Equal -Actual (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -Expected $sentinelHash -Message 'symbolic-link archive changed the outside sentinel'
            $staging = @(Get-ChildItem -LiteralPath $script:TestRoot -Directory -Force | Where-Object { $_.Name.StartsWith(".coldshelf-restore-$id-", [StringComparison]::OrdinalIgnoreCase) })
            Assert-Equal -Actual $staging.Count -Expected 0 -Message 'hot created extraction staging before rejecting the symbolic link'
        }
        finally {
            Remove-TestOwnedPath -Path $directory -Root $script:TestRoot
        }
    }

    Invoke-TestCase 'tar override rejects an invalid test capability without touching source' {
        $source = Join-Path $script:TestRoot 'unauthenticated tar override source'
        New-TestDataset -Path $source -Marker 'unauthenticated-tar'
        $snapshot = Get-TreeSnapshot -Path $source
        $archivesPath = Join-Path $script:ArchiveRoot 'archives'
        $beforeDirectories = @(Get-ChildItem -LiteralPath $archivesPath -Directory -Force | ForEach-Object FullName)
        $injectedTar = Join-Path $script:TestRoot 'unauthenticated-tar.exe'
        [IO.File]::Copy((Join-Path $env:SystemRoot 'System32\where.exe'), $injectedTar, $true)
        try {
            $result = Invoke-ColdShelf -Arguments @('cold', $source, '--remove') -Environment @{
                COLDSHELF_TAR_PATH = $injectedTar
                COLDSHELF_TEST_TOKEN = 'invalid-test-token'
            }
            Assert-ExitCode -Result $result -Expected 6 -Message 'unauthenticated tar override should return Tar exit code 6'
            Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'unauthenticated tar override removed the source'
            Assert-Equal -Actual (Get-TreeSnapshot -Path $source) -Expected $snapshot -Message 'unauthenticated tar override changed source data'
        }
        finally {
            foreach ($directory in @(Get-ChildItem -LiteralPath $archivesPath -Directory -Force | Where-Object { $_.FullName -notin $beforeDirectories })) {
                Remove-TestOwnedPath -Path $directory.FullName -Root $script:TestRoot
            }
        }
    }

    Invoke-TestCase 'Defender fake mode rejects an invalid capability before creating a session' {
        $target = Join-Path $script:TestRoot 'paxsize'
        Assert-True -Condition (-not (Test-Path -LiteralPath $target)) -Message 'unauthenticated Defender target fixture unexpectedly exists'
        $beforeSessions = @(Get-DefenderSessionDirectories | ForEach-Object FullName)
        $hot = Invoke-ColdShelf -Arguments @('hot', '20000101-000000-paxok1', '-d') -Environment @{
            COLDSHELF_DEFENDER_TEST_MODE = 'success'
            COLDSHELF_TEST_TOKEN = 'invalid-test-token'
        }
        Assert-ExitCode -Result $hot -Expected 9 -Message 'unauthenticated Defender fake mode should return Defender exit code 9'
        Assert-True -Condition (-not (Test-Path -LiteralPath $target)) -Message 'unauthenticated Defender fake mode published a restore target'
        $afterSessions = @(Get-DefenderSessionDirectories | ForEach-Object FullName)
        Assert-Equal -Actual (($afterSessions | Sort-Object) -join '|') -Expected (($beforeSessions | Sort-Object) -join '|') -Message 'unauthenticated Defender fake mode created a session'
    }

    Invoke-TestCase 'stats succeeds immediately after init with empty history' {
        $stats = Invoke-ColdShelf -Arguments @('stats')
        Assert-Succeeded -Result $stats -Message 'empty stats should succeed immediately after init'
        $text = $stats.StdOut + $stats.StdErr
        Assert-Matches -Actual $text -Pattern '(?i)Cold operations:\s+0' -Message 'empty stats should report zero cold operations'
        Assert-Matches -Actual $text -Pattern '(?i)Hot operations:\s+0' -Message 'empty stats should report zero hot operations'
    }

    $keepSource = Join-Path $script:TestRoot 'source keep 空格中文'
    New-TestDataset -Path $keepSource -Marker 'keep'
    $keepSnapshot = Get-TreeSnapshot -Path $keepSource
    $keepRecord = $null

    Invoke-TestCase 'cold --keep archives rich Unicode data without deleting source' {
        $keepRecord = Invoke-ColdAndGetArchive -SourcePath $keepSource -Mode '--keep'
        $script:KeepRecord = $keepRecord
        Assert-True -Condition (Test-Path -LiteralPath $keepSource -PathType Container) -Message 'cold --keep deleted the source directory'
        Assert-Equal -Actual (Get-TreeSnapshot -Path $keepSource) -Expected $keepSnapshot -Message 'cold --keep changed source data'
        Assert-Equal -Actual ([string]$keepRecord.Meta.name) -Expected ([IO.Path]::GetFileName($keepSource)) -Message 'metadata name is incorrect'
        Assert-Equal -Actual ([IO.Path]::GetFullPath([string]$keepRecord.Meta.sourcePath)) -Expected ([IO.Path]::GetFullPath($keepSource)) -Message 'metadata sourcePath is incorrect'
        $tarFiles = @(Get-ChildItem -LiteralPath $keepRecord.Directory -File -Recurse -Filter '*.tar')
        Assert-Equal -Actual $tarFiles.Count -Expected 1 -Message 'archive directory should contain one tar file'
        Assert-True -Condition ($tarFiles[0].Length -gt 0) -Message 'tar file is empty'
    }

    Invoke-TestCase 'verify --full, info, and list expose the kept archive' {
        $record = $script:KeepRecord
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$record.Meta.archiveSha256)) -Message 'metadata archiveSha256 was not recorded'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $record.Directory 'manifest.json') -PathType Leaf) -Message 'manifest.json was not published'
        $verify = Invoke-ColdShelf -Arguments @('verify', $record.Id, '--full')
        Assert-Succeeded -Result $verify -Message 'verify --full should succeed'
        Assert-Matches -Actual ($verify.StdOut + $verify.StdErr) -Pattern '(?i)SHA-256' -Message 'verify --full should report the archive SHA-256'

        $info = Invoke-ColdShelf -Arguments @('info', $record.Id)
        Assert-Succeeded -Result $info -Message 'info should succeed'
        Assert-Matches -Actual ($info.StdOut + $info.StdErr) -Pattern ([regex]::Escape([string]$record.Meta.name)) -Message 'info output should include archive name'

        $list = Invoke-ColdShelf -Arguments @('list')
        Assert-Succeeded -Result $list -Message 'list should succeed'
        Assert-Matches -Actual ($list.StdOut + $list.StdErr) -Pattern ([regex]::Escape($record.Id.Substring(0, [Math]::Min(8, $record.Id.Length)))) -Message 'list output should include archive id'
    }

    Invoke-TestCase 'archive-removal quarantine is excluded from list and lookup' {
        $record = $script:KeepRecord
        $quarantine = Join-Path (Join-Path $script:ArchiveRoot 'archives') ".coldshelf-remove-archive-$($record.Id)-enumeration-test"
        Copy-Item -LiteralPath $record.Directory -Destination $quarantine -Recurse -Force
        try {
            $info = Invoke-ColdShelf -Arguments @('info', $record.Id)
            Assert-Succeeded -Result $info -Message 'archive lookup should ignore an archive-removal quarantine with the same metadata ID'
            $list = Invoke-ColdShelf -Arguments @('list')
            Assert-Succeeded -Result $list -Message 'list should ignore archive-removal quarantine directories'
        }
        finally {
            Remove-TestOwnedPath -Path $quarantine -Root $script:TestRoot
        }
    }

    Invoke-TestCase 'hot refuses an existing target, then restores exact data after target removal' {
        $record = $script:KeepRecord
        $beforeConflict = Get-TreeSnapshot -Path $keepSource
        $conflict = Invoke-ColdShelf -Arguments @('hot', $record.Id)
        Assert-ExitCode -Result $conflict -Expected 4 -Message 'hot should refuse an existing target directory with Conflict exit code'
        Assert-Equal -Actual (Get-TreeSnapshot -Path $keepSource) -Expected $beforeConflict -Message 'failed hot changed the existing target'

        Remove-TestOwnedPath -Path $keepSource -Root $script:TestRoot
        $hot = Invoke-ColdShelf -Arguments @('hot', $record.Id)
        Assert-Succeeded -Result $hot -Message 'hot should restore to the original source path'
        Assert-True -Condition (Test-Path -LiteralPath $keepSource -PathType Container) -Message 'hot did not recreate the source directory'
        Assert-Equal -Actual (Get-TreeSnapshot -Path $keepSource) -Expected $keepSnapshot -Message 'hot-restored tree differs from original data'
        Assert-True -Condition (Test-Path -LiteralPath $record.Directory -PathType Container) -Message 'hot should retain the HDD archive'
    }

    Invoke-TestCase 'PAX paths beyond the USTAR name boundary survive cold verify and hot' {
        $source = Join-Path $script:TestRoot 'pax-git-pack-fixture'
        $packDirectory = Join-Path $source 'v6.0\esp-idf\.git\modules\components\unity\unity\objects\pack'
        New-Item -ItemType Directory -Path $packDirectory -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $source 'empty directory') -Force | Out-Null

        $packStem = 'pack-57ec9c912a70f751f7de120c0e0221aaedf96db9'
        foreach ($extension in @('idx', 'pack', 'rev')) {
            $filePath = Join-Path $packDirectory "$packStem.$extension"
            [IO.File]::WriteAllBytes($filePath, [Text.Encoding]::UTF8.GetBytes("pax-$extension-content-中文"))
            $archiveEntry = (([IO.Path]::GetFileName($source)) + '/' + [IO.Path]::GetRelativePath($source, $filePath).Replace('\', '/'))
            Assert-True -Condition ([Text.Encoding]::UTF8.GetByteCount($archiveEntry) -gt 100) -Message "fixture archive path must exceed 100 UTF-8 bytes: $archiveEntry"
        }

        $snapshot = Get-TreeSnapshot -Path $source
        $record = Invoke-ColdAndGetArchive -SourcePath $source -Mode '--keep'
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'long-path cold --keep deleted the source'

        $verify = Invoke-ColdShelf -Arguments @('verify', $record.Id, '--full')
        Assert-Succeeded -Result $verify -Message 'verify --full should accept the long PAX paths'

        Remove-TestOwnedPath -Path $source -Root $script:TestRoot
        $hot = Invoke-ColdShelf -Arguments @('hot', $record.Id)
        Assert-Succeeded -Result $hot -Message 'hot should restore the long PAX paths'
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'hot did not recreate the long-path source'
        Assert-Equal -Actual (Get-TreeSnapshot -Path $source) -Expected $snapshot -Message 'long PAX path restore differs from the original tree'
    }

    Invoke-TestCase 'cold accepts a relative directory whose name starts with a hyphen' {
        $hyphenName = '-leading cold directory 中文'
        $source = Join-Path $script:WorkRoot $hyphenName
        New-TestDataset -Path $source -Marker 'hyphen-leading'
        $record = Invoke-ColdAndGetArchive -SourcePath $hyphenName -Mode '--keep'
        Assert-Equal -Actual ([string]$record.Meta.name) -Expected $hyphenName -Message 'cold did not preserve the hyphen-leading directory name'
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'cold --keep removed the hyphen-leading source'
    }

    Invoke-TestCase 'unknown hot option returns Usage exit code 2' {
        $result = Invoke-ColdShelf -Arguments @('hot', $script:KeepRecord.Id, '--unknown-hot-option')
        Assert-ExitCode -Result $result -Expected 2 -Message 'unknown hot option should return Usage exit code'
    }

    $removeSource = Join-Path $script:TestRoot 'source remove 中文'
    New-TestDataset -Path $removeSource -Marker 'remove'
    $removeSnapshot = Get-TreeSnapshot -Path $removeSource

    Invoke-TestCase 'cold --remove deletes only after a valid archive and hot restores it' {
        $record = Invoke-ColdAndGetArchive -SourcePath $removeSource -Mode '--remove'
        $script:RemoveRecord = $record
        Assert-True -Condition (-not (Test-Path -LiteralPath $removeSource)) -Message 'cold --remove left the source directory behind'
        Assert-True -Condition ([bool]$record.Meta.sourceRemoved) -Message 'cold --remove metadata did not record source removal'
        Assert-True -Condition (-not [bool]$record.Meta.sourceRemovalPending) -Message 'cold --remove metadata remained pending after successful cleanup'
        Assert-True -Condition ($null -eq $record.Meta.sourceQuarantine) -Message 'cold --remove metadata retained a completed source quarantine'
        $sourceQuarantines = @(Get-ChildItem -LiteralPath (Split-Path -Path $removeSource -Parent) -Directory -Force | Where-Object Name -like ".coldshelf-delete-$($record.Id)-*")
        $sourceOwnership = @(Get-ChildItem -LiteralPath (Split-Path -Path $removeSource -Parent) -File -Force | Where-Object Name -like ".coldshelf-delete-$($record.Id)-*.coldshelf-owner")
        Assert-Equal -Actual $sourceQuarantines.Count -Expected 0 -Message 'cold --remove left a source deletion quarantine behind'
        Assert-Equal -Actual $sourceOwnership.Count -Expected 0 -Message 'cold --remove left a source quarantine ownership record behind'

        $verify = Invoke-ColdShelf -Arguments @('verify', $record.Id)
        Assert-Succeeded -Result $verify -Message 'verify should succeed for cold --remove archive'

        $hot = Invoke-ColdShelf -Arguments @('hot', $record.Id)
        Assert-Succeeded -Result $hot -Message 'hot should restore cold --remove data'
        Assert-Equal -Actual (Get-TreeSnapshot -Path $removeSource) -Expected $removeSnapshot -Message 'restored cold --remove data differs from original'
        $restoredMetadata = Read-RequiredJson -Path $record.MetaPath
        Assert-True -Condition (-not [bool]$restoredMetadata.sourceRemovalPending) -Message 'hot did not clear source removal pending state'
        Assert-True -Condition ($null -eq $restoredMetadata.sourceQuarantine) -Message 'hot retained a stale source quarantine path'
    }

    Invoke-TestCase 'hot -d fake success restores target and records exact session paths' {
        $source = Join-Path $script:TestRoot 'defender fake success target 中文'
        New-TestDataset -Path $source -Marker 'defender-success'
        $snapshot = Get-TreeSnapshot -Path $source
        $record = Invoke-ColdAndGetArchive -SourcePath $source -Mode '--keep'
        Remove-TestOwnedPath -Path $source -Root $script:TestRoot
        $beforeSessions = @(Get-DefenderSessionDirectories | ForEach-Object FullName)

        $hot = Invoke-ColdShelf -Arguments @('hot', $record.Id, '-d') -Environment @{ COLDSHELF_DEFENDER_TEST_MODE = 'success' }
        Assert-Succeeded -Result $hot -Message 'hot -d should succeed in fake success mode'
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'hot -d fake success did not restore the target'
        Assert-Equal -Actual (Get-TreeSnapshot -Path $source) -Expected $snapshot -Message 'hot -d fake success restored different data'

        $session = Get-NewDefenderSession -BeforePaths $beforeSessions
        $request = Read-RequiredJson -Path (Join-Path $session.FullName 'request.json')
        $result = Read-RequiredJson -Path (Join-Path $session.FullName 'result.json')
        $requestPaths = @($request.paths)
        Assert-Equal -Actual $requestPaths.Count -Expected 2 -Message 'Defender request must contain exactly two paths'
        $expectedStagingPrefix = ".coldshelf-restore-$($record.Id)-"
        $stagingPath = [IO.Path]::GetFullPath([string]$requestPaths[0])
        Assert-Equal -Actual ([IO.Path]::GetFullPath((Split-Path -Path $stagingPath -Parent))) -Expected ([IO.Path]::GetFullPath((Split-Path -Path $source -Parent))) -Message 'Defender request staging parent is incorrect'
        Assert-True -Condition ((Split-Path -Path $stagingPath -Leaf).StartsWith($expectedStagingPrefix, [StringComparison]::OrdinalIgnoreCase)) -Message 'Defender request staging path has an unexpected name'
        Assert-PathArraysEqual -Actual $requestPaths -Expected @($stagingPath, $source) -Message 'Defender request paths'
        Assert-True -Condition ([bool]$result.cleanupSucceeded) -Message 'fake success helper should report cleanupSucceeded true'
        Assert-NoRestoreStaging -Target $source -ArchiveId $record.Id
    }

    Invoke-TestCase 'hot -d fake pre-existing handles long request paths without owning exclusions' {
        $longParent = Join-Path $script:TestRoot ('long parent ' + ('a' * 48))
        $longParent = Join-Path $longParent ('nested ' + ('b' * 48))
        $source = Join-Path $longParent ('pre-existing target ' + ('c' * 48))
        New-TestDataset -Path $source -Marker 'defender-pre-existing'
        $snapshot = Get-TreeSnapshot -Path $source
        $record = Invoke-ColdAndGetArchive -SourcePath $source -Mode '--keep'
        Remove-TestOwnedPath -Path $source -Root $script:TestRoot
        $beforeSessions = @(Get-DefenderSessionDirectories | ForEach-Object FullName)

        $hot = Invoke-ColdShelf -Arguments @('hot', $record.Id, '--defender-exclusion') -Environment @{ COLDSHELF_DEFENDER_TEST_MODE = 'pre-existing' }
        Assert-Succeeded -Result $hot -Message 'hot -d should succeed when both fake exclusions pre-exist'
        Assert-Equal -Actual (Get-TreeSnapshot -Path $source) -Expected $snapshot -Message 'fake pre-existing restore differs from original data'

        $session = Get-NewDefenderSession -BeforePaths $beforeSessions
        $request = Read-RequiredJson -Path (Join-Path $session.FullName 'request.json')
        $ready = Read-RequiredJson -Path (Join-Path $session.FullName 'ready.json')
        $result = Read-RequiredJson -Path (Join-Path $session.FullName 'result.json')
        $requestPaths = @($request.paths)
        Assert-Equal -Actual $requestPaths.Count -Expected 2 -Message 'long fake request should contain exactly two paths'
        Assert-True -Condition ([string]$requestPaths[0] -ne [string]$requestPaths[1]) -Message 'long fake request paths should be distinct'
        Assert-Equal -Actual @($ready.ownedPaths).Count -Expected 0 -Message 'fake pre-existing ready state should own no paths'
        Assert-PathArraysEqual -Actual @($ready.preExistingPaths) -Expected @([string]$requestPaths[0], [string]$requestPaths[1]) -Message 'fake pre-existing ready paths'
        Assert-Equal -Actual @($result.ownedPaths).Count -Expected 0 -Message 'fake pre-existing result should own no paths'
        Assert-PathArraysEqual -Actual @($result.preExistingPaths) -Expected @([string]$requestPaths[0], [string]$requestPaths[1]) -Message 'fake pre-existing result paths'
        Assert-True -Condition ([bool]$result.cleanupSucceeded) -Message 'fake pre-existing cleanup should succeed'
    }

    Invoke-TestCase 'hot -d fake add failure returns Defender 9 and cleans staging' {
        $source = Join-Path $script:TestRoot 'defender fake add failure target'
        New-TestDataset -Path $source -Marker 'defender-add-fail'
        $record = Invoke-ColdAndGetArchive -SourcePath $source -Mode '--keep'
        Remove-TestOwnedPath -Path $source -Root $script:TestRoot
        $beforeSessions = @(Get-DefenderSessionDirectories | ForEach-Object FullName)

        $hot = Invoke-ColdShelf -Arguments @('hot', $record.Id, '-d') -Environment @{ COLDSHELF_DEFENDER_TEST_MODE = 'add-fail' }
        Assert-ExitCode -Result $hot -Expected 9 -Message 'fake Defender add failure should return exit code 9'
        Assert-True -Condition (-not (Test-Path -LiteralPath $source)) -Message 'fake add failure should not publish the restore target'
        Assert-NoRestoreStaging -Target $source -ArchiveId $record.Id
        $session = Get-NewDefenderSession -BeforePaths $beforeSessions
        $ready = Read-RequiredJson -Path (Join-Path $session.FullName 'ready.json')
        Assert-True -Condition (-not [bool]$ready.ready) -Message 'fake add failure helper unexpectedly became ready'
    }

    Invoke-TestCase 'hot -d fake remove failure returns Degraded 10 after publishing data' {
        $source = Join-Path $script:TestRoot 'defender fake remove failure target'
        New-TestDataset -Path $source -Marker 'defender-remove-fail'
        $snapshot = Get-TreeSnapshot -Path $source
        $record = Invoke-ColdAndGetArchive -SourcePath $source -Mode '--keep'
        Remove-TestOwnedPath -Path $source -Root $script:TestRoot
        $beforeSessions = @(Get-DefenderSessionDirectories | ForEach-Object FullName)

        $hot = Invoke-ColdShelf -Arguments @('hot', $record.Id, '-d') -Environment @{ COLDSHELF_DEFENDER_TEST_MODE = 'remove-fail' }
        Assert-ExitCode -Result $hot -Expected 10 -Message 'fake Defender remove failure should return degraded exit code 10'
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'fake remove failure should leave restored target available'
        Assert-Equal -Actual (Get-TreeSnapshot -Path $source) -Expected $snapshot -Message 'fake remove failure restored different data'
        $metadata = Read-RequiredJson -Path $record.MetaPath
        Assert-Equal -Actual ([string]$metadata.status) -Expected 'hot' -Message 'metadata should be hot after published degraded restore'
        $session = Get-NewDefenderSession -BeforePaths $beforeSessions
        $result = Read-RequiredJson -Path (Join-Path $session.FullName 'result.json')
        Assert-True -Condition (-not [bool]$result.cleanupSucceeded) -Message 'fake remove failure should report cleanupSucceeded false'
        Assert-NoRestoreStaging -Target $source -ArchiveId $record.Id
    }

    Invoke-TestCase 'hot -d existing target returns Conflict 4 without creating a Defender session' {
        $record = $script:KeepRecord
        Assert-True -Condition (Test-Path -LiteralPath $keepSource -PathType Container) -Message 'existing-target fixture is missing'
        $beforeSessions = @(Get-DefenderSessionDirectories | ForEach-Object FullName)
        $hot = Invoke-ColdShelf -Arguments @('hot', $record.Id, '-d') -Environment @{ COLDSHELF_DEFENDER_TEST_MODE = 'success' }
        Assert-ExitCode -Result $hot -Expected 4 -Message 'hot -d should reject an existing target with Conflict exit code'
        $afterSessions = @(Get-DefenderSessionDirectories | ForEach-Object FullName)
        Assert-Equal -Actual (($afterSessions | Sort-Object) -join '|') -Expected (($beforeSessions | Sort-Object) -join '|') -Message 'existing-target hot -d created a Defender session'
    }

    Invoke-TestCase 'history and stats record separate cold and hot operations' {
        $historyPath = Join-Path $script:ColdShelfHome 'history.json'
        Assert-True -Condition (Test-Path -LiteralPath $historyPath -PathType Leaf) -Message 'history.json was not created'
        $historyText = Get-Content -LiteralPath $historyPath -Raw
        $null = $historyText | ConvertFrom-Json
        Assert-Matches -Actual $historyText -Pattern '(?i)cold' -Message 'history does not contain a cold operation'
        Assert-Matches -Actual $historyText -Pattern '(?i)hot' -Message 'history does not contain a hot operation'

        $stats = Invoke-ColdShelf -Arguments @('stats')
        Assert-Succeeded -Result $stats -Message 'stats should succeed'
        $statsText = $stats.StdOut + $stats.StdErr
        Assert-Matches -Actual $statsText -Pattern '(?i)cold' -Message 'stats output does not report cold operations'
        Assert-Matches -Actual $statsText -Pattern '(?i)hot' -Message 'stats output does not report hot operations'
    }

    Invoke-TestCase 'list ignores a damaged index and doctor rebuilds it' {
        $indexPath = Join-Path $script:ArchiveRoot 'index.json'
        Assert-True -Condition (Test-Path -LiteralPath $indexPath -PathType Leaf) -Message 'index.json was not created'
        [IO.File]::WriteAllText($indexPath, '{ deliberately damaged index', [Text.UTF8Encoding]::new($false))

        $list = Invoke-ColdShelf -Arguments @('list')
        Assert-Succeeded -Result $list -Message 'list should scan metadata even when index.json is damaged'
        Assert-Matches -Actual ($list.StdOut + $list.StdErr) -Pattern ([regex]::Escape($script:KeepRecord.Id.Substring(0, [Math]::Min(8, $script:KeepRecord.Id.Length)))) -Message 'list lost valid archives when index was damaged'

        $doctor = Invoke-ColdShelf -Arguments @('doctor')
        Assert-Succeeded -Result $doctor -Message 'doctor should rebuild a damaged index'
        $rebuilt = Get-Content -LiteralPath $indexPath -Raw
        $null = $rebuilt | ConvertFrom-Json
        Assert-Matches -Actual $rebuilt -Pattern ([regex]::Escape($script:KeepRecord.Id)) -Message 'rebuilt index does not include a valid archive'
    }

    Invoke-TestCase 'doctor reports pending source removal without changing quarantine data' {
        $record = $script:KeepRecord
        $originalMetadataText = Get-Content -LiteralPath $record.MetaPath -Raw
        $quarantine = Join-Path $script:TestRoot ".coldshelf-delete-$($record.Id)-doctor"
        New-TestDataset -Path $quarantine -Marker 'doctor-pending'
        $snapshot = Get-TreeSnapshot -Path $quarantine
        try {
            $metadata = $originalMetadataText | ConvertFrom-Json
            $metadata.sourceRemovalPending = $true
            $metadata.sourceQuarantine = $quarantine
            [IO.File]::WriteAllText($record.MetaPath, (($metadata | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

            $doctor = Invoke-ColdShelf -Arguments @('doctor')
            Assert-ExitCode -Result $doctor -Expected 10 -Message 'doctor should return degraded for pending source removal'
            $text = $doctor.StdOut + $doctor.StdErr
            Assert-Matches -Actual $text -Pattern '(?i)source removal is pending' -Message 'doctor did not report pending source removal'
            Assert-Matches -Actual $text -Pattern ([regex]::Escape($quarantine)) -Message 'doctor did not report the recorded source quarantine'
            Assert-True -Condition (Test-Path -LiteralPath $quarantine -PathType Container) -Message 'doctor deleted the recorded source quarantine'
            Assert-Equal -Actual (Get-TreeSnapshot -Path $quarantine) -Expected $snapshot -Message 'doctor changed source quarantine data'
        }
        finally {
            [IO.File]::WriteAllText($record.MetaPath, $originalMetadataText, [Text.UTF8Encoding]::new($false))
            Remove-TestOwnedPath -Path $quarantine -Root $script:TestRoot
        }
    }

    Invoke-TestCase 'duplicate names are rejected as ambiguous' {
        $sameName = 'same archive name 中文'
        $sourceA = Join-Path (Join-Path $script:TestRoot 'ambiguity A') $sameName
        $sourceB = Join-Path (Join-Path $script:TestRoot 'ambiguity B') $sameName
        New-TestDataset -Path $sourceA -Marker 'ambiguous-a'
        New-TestDataset -Path $sourceB -Marker 'ambiguous-b'
        $recordA = Invoke-ColdAndGetArchive -SourcePath $sourceA -Mode '--keep'
        $recordB = Invoke-ColdAndGetArchive -SourcePath $sourceB -Mode '--keep'

        $ambiguous = Invoke-ColdShelf -Arguments @('info', $sameName)
        Assert-Failed -Result $ambiguous -Message 'name lookup should fail when more than one archive has the same name'
        $text = $ambiguous.StdOut + $ambiguous.StdErr
        Assert-Matches -Actual $text -Pattern '(?i)(ambig|multiple|candidate|歧义|多个|候选)' -Message 'ambiguous lookup should explain the ambiguity'
        Assert-Matches -Actual $text -Pattern ([regex]::Escape($recordA.Id.Substring(0, [Math]::Min(8, $recordA.Id.Length)))) -Message 'ambiguity output should identify the first candidate'
        Assert-Matches -Actual $text -Pattern ([regex]::Escape($recordB.Id.Substring(0, [Math]::Min(8, $recordB.Id.Length)))) -Message 'ambiguity output should identify the second candidate'
    }

    Invoke-TestCase 'remove refuses the only cold copy' {
        $source = Join-Path $script:TestRoot 'remove safety unique copy'
        New-TestDataset -Path $source -Marker 'unique-copy'
        $record = Invoke-ColdAndGetArchive -SourcePath $source -Mode '--remove'
        Assert-True -Condition (-not (Test-Path -LiteralPath $source)) -Message 'test precondition failed: source should be absent'

        $remove = Invoke-ColdShelf -Arguments @('remove', $record.Id, '--yes')
        Assert-Failed -Result $remove -Message 'remove must refuse to delete the only remaining cold copy'
        Assert-True -Condition (Test-Path -LiteralPath $record.Directory -PathType Container) -Message 'remove deleted the only cold copy'
    }

    Invoke-TestCase 'remove refuses same-length content tampering with Integrity exit code 7' {
        $source = Join-Path $script:TestRoot 'remove safety mismatch'
        New-TestDataset -Path $source -Marker 'mismatch'
        $record = Invoke-ColdAndGetArchive -SourcePath $source -Mode '--keep'
        $tamperedPath = Join-Path $source 'plain.txt'
        $originalBytes = [IO.File]::ReadAllBytes($tamperedPath)
        Assert-True -Condition ($originalBytes.Length -gt 0) -Message 'tamper fixture must not be empty'
        $tamperedBytes = [byte[]]$originalBytes.Clone()
        $tamperedBytes[0] = $tamperedBytes[0] -bxor 1
        [IO.File]::WriteAllBytes($tamperedPath, $tamperedBytes)
        Assert-Equal -Actual ([IO.FileInfo]::new($tamperedPath).Length) -Expected $originalBytes.Length -Message 'tamper fixture length changed'

        $remove = Invoke-ColdShelf -Arguments @('remove', $record.Id, '--yes')
        Assert-ExitCode -Result $remove -Expected 7 -Message 'remove must report Integrity for same-length content tampering'
        Assert-True -Condition (Test-Path -LiteralPath $record.Directory -PathType Container) -Message 'remove deleted an archive despite source tampering'
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'remove unexpectedly deleted the tampered source tree'
    }

    Invoke-TestCase 'remove deletes an archive only when a verified source copy remains' {
        $source = Join-Path $script:TestRoot 'remove safety verified copy'
        New-TestDataset -Path $source -Marker 'verified-copy'
        $snapshot = Get-TreeSnapshot -Path $source
        $record = Invoke-ColdAndGetArchive -SourcePath $source -Mode '--keep'

        $remove = Invoke-ColdShelf -Arguments @('remove', $record.Id, '--yes')
        Assert-Succeeded -Result $remove -Message 'remove should allow deletion when a matching source copy exists'
        Assert-True -Condition (-not (Test-Path -LiteralPath $record.Directory)) -Message 'remove left the archive directory behind'
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'remove deleted the source instead of the archive'
        Assert-Equal -Actual (Get-TreeSnapshot -Path $source) -Expected $snapshot -Message 'remove changed the verified source copy'
        $sourceQuarantines = @(Get-ChildItem -LiteralPath (Split-Path -Path $source -Parent) -Directory -Force | Where-Object Name -like ".coldshelf-delete-$($record.Id)-*")
        $sourceOwnership = @(Get-ChildItem -LiteralPath (Split-Path -Path $source -Parent) -File -Force | Where-Object Name -like ".coldshelf-delete-$($record.Id)-*.coldshelf-owner")
        $archiveQuarantines = @(Get-ChildItem -LiteralPath (Join-Path $script:ArchiveRoot 'archives') -Directory -Force | Where-Object Name -like ".coldshelf-remove-archive-$($record.Id)-*")
        $archiveOwnership = @(Get-ChildItem -LiteralPath (Join-Path $script:ArchiveRoot 'archives') -File -Force | Where-Object Name -like ".coldshelf-remove-archive-$($record.Id)-*.coldshelf-owner")
        Assert-Equal -Actual $sourceQuarantines.Count -Expected 0 -Message 'remove left a source quarantine behind'
        Assert-Equal -Actual $sourceOwnership.Count -Expected 0 -Message 'remove left a source quarantine ownership record behind'
        Assert-Equal -Actual $archiveQuarantines.Count -Expected 0 -Message 'remove left an archive quarantine behind'
        Assert-Equal -Actual $archiveOwnership.Count -Expected 0 -Message 'remove left an archive quarantine ownership record behind'
    }

    Invoke-TestCase 'tar exit zero without an archive preserves the source and publishes nothing' {
        $source = Join-Path $script:TestRoot 'tar fake success source 中文'
        New-TestDataset -Path $source -Marker 'tar-fake-success'
        $snapshot = Get-TreeSnapshot -Path $source
        $beforeIds = @(Get-ArchiveRecords | ForEach-Object Id)
        $fakeSuccessTar = Join-Path $script:TestRoot 'fake-success-tar.exe'
        [IO.File]::Copy($env:ComSpec, $fakeSuccessTar, $true)
        Assert-True -Condition (Test-Path -LiteralPath $fakeSuccessTar -PathType Leaf) -Message 'cmd.exe fake-success injector is unavailable'

        $result = Invoke-ColdShelf -Arguments @('cold', $source, '--remove') -Environment @{ COLDSHELF_TAR_PATH = $fakeSuccessTar }
        Assert-ExitCode -Result $result -Expected 7 -Message 'tar exit zero without a non-empty archive should return Integrity'
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'fake-success tar deleted the original source directory'
        Assert-Equal -Actual (Get-TreeSnapshot -Path $source) -Expected $snapshot -Message 'fake-success tar changed the original source data'
        $afterIds = @(Get-ArchiveRecords | ForEach-Object Id)
        Assert-Equal -Actual (($afterIds | Sort-Object) -join '|') -Expected (($beforeIds | Sort-Object) -join '|') -Message 'fake-success tar published a formal archive'
    }

    Invoke-TestCase 'injected tar failure returns nonzero and preserves the source' {
        $source = Join-Path $script:TestRoot 'tar failure source 中文'
        New-TestDataset -Path $source -Marker 'tar-failure'
        $snapshot = Get-TreeSnapshot -Path $source
        $beforeIds = @(Get-ArchiveRecords | ForEach-Object Id)
        $failingTar = Join-Path $script:TestRoot 'failing-tar.exe'
        [IO.File]::Copy((Join-Path $env:SystemRoot 'System32\where.exe'), $failingTar, $true)
        Assert-True -Condition (Test-Path -LiteralPath $failingTar -PathType Leaf) -Message 'where.exe failure injector is unavailable'

        $result = Invoke-ColdShelf -Arguments @('cold', $source, '--remove') -Environment @{ COLDSHELF_TAR_PATH = $failingTar }
        Assert-Failed -Result $result -Message 'cold should fail when the injected tar command returns nonzero'
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'tar failure deleted the original source directory'
        Assert-Equal -Actual (Get-TreeSnapshot -Path $source) -Expected $snapshot -Message 'tar failure changed the original source data'
        $afterIds = @(Get-ArchiveRecords | ForEach-Object Id)
        Assert-Equal -Actual (($afterIds | Sort-Object) -join '|') -Expected (($beforeIds | Sort-Object) -join '|') -Message 'tar failure published a formal archive'
    }
}
finally {
    $rootFull = [IO.Path]::GetFullPath($script:TestRoot)
    $rootParent = [IO.Path]::GetFullPath([IO.Directory]::GetParent($rootFull).FullName).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $safeName = [IO.Path]::GetFileName($rootFull).StartsWith('ColdShelf-tests-', [StringComparison]::Ordinal)
    $markerMatches = (Test-Path -LiteralPath $ownershipMarker -PathType Leaf) -and ((Get-Content -LiteralPath $ownershipMarker -Raw) -eq $ownershipToken)

    if ($rootParent -eq $tempBase -and $safeName -and $markerMatches) {
        Get-ChildItem -LiteralPath $rootFull -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.Attributes = [IO.FileAttributes]::Normal } catch { }
        }
        Remove-Item -LiteralPath $rootFull -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Warning "Safety check refused cleanup of test root: $rootFull"
    }
}

Write-Host ''
Write-Host ('Result: {0} passed, {1} failed.' -f $script:Passed, $script:Failed)
if ($script:Failures.Count -gt 0) {
    Write-Host 'Failures:'
    foreach ($failure in $script:Failures) {
        Write-Host " - $failure"
    }
    exit 1
}

exit 0
