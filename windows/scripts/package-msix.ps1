<#
Builds the Microsoft Store upload from the published Yowl.exe files.

    ./scripts/package-msix.ps1 -IdentityName 12345Name.Yowl -Publisher "CN=..." -PublisherDisplayName "..."

Expects out/win-x64/Yowl.exe and out/win-arm64/Yowl.exe (dotnet publish, as in
the README). Writes out/store/Yowl_<version>.msixbundle and a .msixupload that
wraps it. Nothing is signed: the Store signs what it publishes. The identity
values are on Partner Center's Product identity page for the app; the
defaults only make a package that builds, not one the Store will accept.

Needs makeappx.exe from the Windows SDK (installed on GitHub's Windows runners).
#>
param(
    [string]$IdentityName = "JernejKoica.Yowl-LaptopTheftAlarm",
    [string]$Publisher = "CN=8F372153-5F48-4D5E-B611-D74BDDD354BF",
    [string]$PublisherDisplayName = "Jernej Kočica",
    [string]$Root = (Join-Path $PSScriptRoot "..")
)
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path $Root).Path

# Empty repository variables arrive as empty strings, not as missing values.
if (-not $IdentityName) { $IdentityName = "JernejKoica.Yowl-LaptopTheftAlarm" }
if (-not $Publisher) { $Publisher = "CN=8F372153-5F48-4D5E-B611-D74BDDD354BF" }
if (-not $PublisherDisplayName) { $PublisherDisplayName = "Jernej Kočica" }

[xml]$props = Get-Content (Join-Path $Root "Directory.Build.props")
$semver = ($props.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1).Version
$version = "$semver.0"

$makeappx = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\makeappx.exe" |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
    Select-Object -First 1
if (-not $makeappx) { throw "makeappx.exe not found: install the Windows SDK." }
# makepri sits beside makeappx. The images are scale- and size-qualified
# (StoreLogo.scale-200.png), and only a resources.pri index lets Windows find
# them from the plain names in the manifest.
$makepri = Join-Path $makeappx.DirectoryName "makepri.exe"
Write-Host "Using $($makeappx.FullName), version $version"

$store = Join-Path $Root "out/store"
$staging = Join-Path $store "staging"
$packages = Join-Path $store "packages"
Remove-Item $store -Recurse -Force -ErrorAction SilentlyContinue
New-Item $packages -ItemType Directory -Force | Out-Null

$template = Get-Content (Join-Path $Root "packaging/Package.appxmanifest") -Raw
foreach ($arch in "x64", "arm64") {
    $exe = Join-Path $Root "out/win-$arch/Yowl.exe"
    if (-not (Test-Path $exe)) { throw "Missing ${exe}: publish win-$arch first." }

    $dir = Join-Path $staging $arch
    New-Item $dir -ItemType Directory -Force | Out-Null
    Copy-Item $exe $dir
    Copy-Item (Join-Path $Root "packaging/Images") (Join-Path $dir "Images") -Recurse

    # SecurityElement.Escape: a publisher such as CN="A & B" must stay valid XML.
    $manifest = $template.
        Replace('$(IdentityName)', [Security.SecurityElement]::Escape($IdentityName)).
        Replace('$(Publisher)', [Security.SecurityElement]::Escape($Publisher)).
        Replace('$(PublisherDisplayName)', [Security.SecurityElement]::Escape($PublisherDisplayName)).
        Replace('$(Version)', $version).
        Replace('$(Architecture)', $arch)
    Set-Content (Join-Path $dir "AppxManifest.xml") $manifest -Encoding utf8

    $priConfig = Join-Path $store "priconfig-$arch.xml"
    & $makepri createconfig /cf $priConfig /dq en-US /pv 10.0.0 /o
    if ($LASTEXITCODE) { throw "makepri createconfig failed" }
    & $makepri new /pr $dir /cf $priConfig /mn (Join-Path $dir "AppxManifest.xml") /of (Join-Path $dir "resources.pri") /o
    if ($LASTEXITCODE) { throw "makepri new failed for $arch" }

    & $makeappx.FullName pack /o /d $dir /p (Join-Path $packages "Yowl_${version}_$arch.msix")
    if ($LASTEXITCODE) { throw "makeappx pack failed for $arch" }
}

$bundle = Join-Path $store "Yowl_$version.msixbundle"
& $makeappx.FullName bundle /o /d $packages /bv $version /p $bundle
if ($LASTEXITCODE) { throw "makeappx bundle failed" }

# A .msixupload is a zip holding the bundle (and optionally symbols).
$upload = Join-Path $store "Yowl_$version.msixupload"
$zip = "$upload.zip"
Compress-Archive -Path $bundle -DestinationPath $zip -Force
Move-Item $zip $upload -Force

Write-Host "Wrote $bundle"
Write-Host "Wrote $upload"
