[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ClientExe,
    [Parameter(Mandatory = $true)][string] $Version,
    [Parameter(Mandatory = $true)][string] $NativeWork,
    [Parameter(Mandatory = $true)][string] $Output
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$client = (Resolve-Path -LiteralPath $ClientExe).Path
& python (Join-Path $root 'packaging\native\check-runtime.py') $client
if ($LASTEXITCODE) { throw 'The client does not have a self-contained native media runtime.' }
$outputDirectory = [IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$intermediate = Join-Path $env:RUNNER_TEMP ('xcoc-wix-' + [guid]::NewGuid())
try {
    $project=Join-Path $root 'packaging\windows\XcocClient.wixproj'
    $common=@('-c','Release',"-p:ClientExe=$client","-p:ProductVersion=$Version","-p:BaseIntermediateOutputPath=$intermediate\obj\")
    & dotnet build $project @common "-p:OutputPath=$intermediate\bootstrap\"
    if ($LASTEXITCODE) { throw 'Bootstrap MSI compilation failed' }
    $bootstrap=Join-Path $intermediate "bootstrap\xcoc-$Version-windows-x64.msi"
    $payload=Join-Path $intermediate 'payload'
    & python (Join-Path $root 'scripts\extract-bootstrap-msi.py') --bootstrap-msi $bootstrap --stage $payload
    if ($LASTEXITCODE) { throw 'Actual MSI payload extraction failed' }
    & python (Join-Path $root 'scripts\wix-runtime-inventory.py') --stage $payload --bootstrap-msi $bootstrap --build-input-root "$intermediate\runtime-inputs" --output "$intermediate\runtime-components.json" --project $project --owned-input (Join-Path $root 'packaging\windows\License.rtf')
    if ($LASTEXITCODE) { throw 'Actual WiX runtime provenance failed' }
& python (Join-Path $root 'scripts/prepare-msi-policy.py') --source (Join-Path $root 'packaging/windows/Package.wxs') --stage $payload --version $Version
if ($LASTEXITCODE) { throw 'Current MSI source installation policy failed' }
    & python (Join-Path $root 'scripts\prepare-desktop-inventory.py') --stage $payload --native-work $NativeWork --target x86_64-pc-windows-msvc --runtime-path xcoc.exe --build-input-root "$intermediate\runtime-inputs" --external-components "$intermediate\runtime-components.json"
    if ($LASTEXITCODE) { throw 'Final native payload inventory failed' }
    & python (Join-Path $root 'scripts\wix-inventory-files.py') --directory "$payload\share" --output "$intermediate\inventory.wxs" --product xcoc
    if ($LASTEXITCODE) { throw 'Full MSI file authoring failed' }
    & dotnet build $project @common '-p:IncludeInventory=1' "-p:InventoryWxs=$intermediate\inventory.wxs" "-p:OutputPath=$outputDirectory\"
    if ($LASTEXITCODE) { throw 'Final MSI compilation failed' }
    $msi = @(Get-ChildItem -LiteralPath $outputDirectory -Filter '*.msi' -File)
    if ($msi.Count -ne 1) { throw "Expected exactly one MSI output; found $($msi.Count)." }
    Copy-Item -LiteralPath (Join-Path $payload 'share\release-sbom.cdx.json') -Destination ($msi[0].FullName+'.inner-sbom.cdx.json')
    Get-ChildItem -LiteralPath $outputDirectory -Filter '*.wixpdb' -File | Remove-Item -Force
    Write-Host "xcoc installer built successfully: $($msi[0].FullName)"
}
finally {
    if (Test-Path -LiteralPath $intermediate) {
        Remove-Item -LiteralPath $intermediate -Recurse -Force
    }
}
