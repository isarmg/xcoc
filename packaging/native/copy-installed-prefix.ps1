[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Destination
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$sourceRoot=(Resolve-Path -LiteralPath $Source).Path
$destinationRoot=[IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationRoot) { throw 'The independent native prefix must be new.' }
if ($destinationRoot.StartsWith($sourceRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'The independent prefix cannot be inside the provider prefix.'
}
$destinationParent=Get-Item -LiteralPath (Split-Path -Parent $destinationRoot)
for ($parent=$destinationParent; $null -ne $parent; $parent=$parent.Parent) {
    if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The independent prefix must use physical directories.' }
}
$sourceDirectory=Get-Item -LiteralPath $sourceRoot
for ($parent=$sourceDirectory; $null -ne $parent; $parent=$parent.Parent) {
    if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The provider prefix must use physical directories.' }
}
function Read-Prefix([string]$RootPath) {
    $directories=[Collections.Generic.Queue[string]]::new()
    $directories.Enqueue($RootPath)
    $directoryNames=[Collections.Generic.List[string]]::new()
    $files=[Collections.Generic.List[object]]::new()
    $count=0
    $bytes=[long]0
    while ($directories.Count) {
        $directory=Get-Item -LiteralPath ($directories.Dequeue())
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Native provider aliases are not copied.' }
        foreach ($entry in Get-ChildItem -LiteralPath $directory.FullName -Force) {
            $count++
            if ($count -gt 32768) { throw 'The native prefix entry bound was exceeded.' }
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Native provider aliases are not copied.' }
            $relative=$entry.FullName.Substring($RootPath.Length).TrimStart('\')
            if ($entry -is [IO.DirectoryInfo]) {
                $directories.Enqueue($entry.FullName)
                $directoryNames.Add($relative)
            } elseif ($entry -is [IO.FileInfo]) {
                if ($entry.Length -gt 268435456) { throw 'The native prefix file bound was exceeded.' }
                $bytes+=$entry.Length
                if ($bytes -gt 2147483648) { throw 'The native prefix total bound was exceeded.' }
                $files.Add([pscustomobject]@{Path=$entry.FullName;Relative=$relative;Length=$entry.Length;Modified=$entry.LastWriteTimeUtc;Attributes=$entry.Attributes;Hash=(Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash})
            } else { throw 'The native prefix contains an unknown filesystem object.' }
        }
    }
    return [pscustomobject]@{Directories=$directoryNames.ToArray();Files=$files.ToArray()}
}
function Check-SourceFile($File) {
    $current=Get-Item -LiteralPath $File.Path
    if ($current -isnot [IO.FileInfo] -or ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $current.Length -ne $File.Length -or $current.LastWriteTimeUtc -ne $File.Modified -or $current.Attributes -ne $File.Attributes) {
        throw 'Native provider file metadata changed during the independent copy.'
    }
    for ($parent=$current.Directory; $null -ne $parent; $parent=$parent.Parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Native provider aliases are not copied.' }
    }
    if ((Get-FileHash -LiteralPath $File.Path -Algorithm SHA256).Hash -ne $File.Hash) {
        throw 'Native provider bytes changed during the independent copy.'
    }
}
$initial=Read-Prefix $sourceRoot
# Copy exactly the reviewed, bounded set, rather than re-enumerating a provider
# cache with Copy-Item -Recurse. CopyTo creates new files, breaking cache links.
New-Item -ItemType Directory -Path $destinationRoot | Out-Null
foreach ($relative in $initial.Directories) {
    $original=Get-Item -LiteralPath (Join-Path $sourceRoot $relative)
    if ($original -isnot [IO.DirectoryInfo] -or ($original.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Native provider directory changed during the independent copy.'
    }
    New-Item -ItemType Directory -Path (Join-Path $destinationRoot $relative) | Out-Null
}
foreach ($file in $initial.Files) {
    Check-SourceFile $file
    $original=Get-Item -LiteralPath $file.Path
    $copied=Join-Path $destinationRoot $file.Relative
    $null=$original.CopyTo($copied,$false)
    Check-SourceFile $file
    if ((Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ne $file.Hash) {
        throw 'Independent native provider bytes differ from the original file.'
    }
}
$sourceFinal=Read-Prefix $sourceRoot
$destinationFinal=Read-Prefix $destinationRoot
foreach ($final in @($sourceFinal,$destinationFinal)) {
    if ($initial.Directories.Length -ne $final.Directories.Length -or
        ($initial.Directories.Length -gt 0 -and (Compare-Object @($initial.Directories | Sort-Object) @($final.Directories | Sort-Object)))) {
        throw 'Native provider directory set changed during the independent copy.'
    }
    $expected=@($initial.Files | ForEach-Object {$_.Relative+'|'+$_.Length+'|'+$_.Hash} | Sort-Object)
    $actual=@($final.Files | ForEach-Object {$_.Relative+'|'+$_.Length+'|'+$_.Hash} | Sort-Object)
    if ($expected.Length -ne $actual.Length -or ($expected.Length -gt 0 -and (Compare-Object $expected $actual))) {
        throw 'Native provider file set changed during the independent copy.'
    }
}
