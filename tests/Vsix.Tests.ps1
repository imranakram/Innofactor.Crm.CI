<#
    The packaging gate: assertions against a built .vsix.

    Every regression this repo has actually shipped would have been caught
    here - DotNetZip riding along in stale bin output, ADAL about to flip
    version, a task missing its cmdlet, screenshots not packaged.

    Pass a specific package with:
        Invoke-Pester ./tests/Vsix.Tests.ps1 -Data @{ VsixPath = 'path/to.vsix' }
    Otherwise the newest .vsix under Extension/VSIX is used.
#>

param(
    [string] $VsixPath
)

BeforeDiscovery {
    . $PSScriptRoot/TestHelpers.ps1
    # -Skip is evaluated during discovery, so the package has to be located here.
    $HaveVsix = [bool](Resolve-VsixPath -VsixPath $VsixPath)
}

BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    $script:Baseline     = Get-PublishedBaseline
    $script:ResolvedVsix = Resolve-VsixPath -VsixPath $VsixPath

    if ($ResolvedVsix) {
        Write-Host "Testing package: $ResolvedVsix"
        $script:Extracted = Expand-Vsix $ResolvedVsix
        $script:Impl      = Join-Path $Extracted 'implementation'
    }
}

AfterAll {
    if ($script:Extracted -and (Test-Path $script:Extracted)) {
        Remove-Item $script:Extracted -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Packaged extension' -Skip:(-not $HaveVsix) {

    Context 'Contents' {

        It 'contains an implementation folder' {
            $Impl | Should -Exist
        }

        It 'packages all nine tasks' {
            @(Get-ChildItem $Impl -Directory).Count | Should -Be 9
        }

        It 'packages the documentation images' {
            foreach ($img in 'tasks','minify','resources','assembly','export') {
                Join-Path $Extracted "documentation/images/$img.png" | Should -Exist
            }
        }
    }

    Context 'DotNetZip has been removed' {

        It 'ships no DotNetZip assembly anywhere' {
            # DotNetZip was replaced by System.IO.Compression, but it kept
            # shipping because pack.ps1 copies *.dll out of a stale bin/Release.
            $found = @(Get-ChildItem $Extracted -Recurse -Force -Filter 'DotNetZip.dll' -ErrorAction SilentlyContinue)
            $found.FullName | Should -BeNullOrEmpty -Because 'clean Cmdlets/*/bin and obj before packing'
        }

        It 'ships no Ionic.Zip assembly anywhere' {
            $found = @(Get-ChildItem $Extracted -Recurse -Force -Filter 'Ionic.Zip*.dll' -ErrorAction SilentlyContinue)
            $found.FullName | Should -BeNullOrEmpty
        }

        It 'ships no NuGet System.IO.Compression assemblies' {
            # The cmdlets use the framework's System.IO.Compression and
            # System.IO.Compression.FileSystem. The 4.3.0 NuGet copies (4.1.2.0 and
            # ZipFile 4.0.2.0) only worked because .NET 4.7.1+ unifies them back to
            # the framework assembly, and would ride along from a stale bin like DotNetZip did.
            $found = @(Get-ChildItem $Extracted -Recurse -Force -Filter 'System.IO.Compression*.dll' -ErrorAction SilentlyContinue)
            $found.FullName | Should -BeNullOrEmpty -Because 'clean Cmdlets/*/bin and obj before packing'
        }
    }

    Context 'ADAL stays pinned at 3.19.8' {

        BeforeAll {
            $script:AdalDlls = @(Get-ChildItem $Extracted -Recurse `
                -Filter 'Microsoft.IdentityModel.Clients.ActiveDirectory.dll' -ErrorAction SilentlyContinue)
        }

        It 'ships ADAL for the cmdlet-backed tasks' {
            $AdalDlls.Count | Should -BeGreaterThan 0
        }

        It 'ships only the pinned ADAL file version' {
            # Xrm.Tooling.Connector 4.0.0.0 is compiled against ADAL 3.19.8.16603
            # exactly, and no binding redirect can apply in a PowerShell-hosted DLL.
            $versions = @($AdalDlls | ForEach-Object {
                [System.Diagnostics.FileVersionInfo]::GetVersionInfo($_.FullName).FileVersion
            } | Sort-Object -Unique)

            $versions | Should -Be @((Get-ExpectedAdalFileVersion))
        }

        It 'ships the 3.x-only Platform satellite beside each ADAL assembly' {
            foreach ($dll in $AdalDlls) {
                Join-Path $dll.Directory.FullName 'Microsoft.IdentityModel.Clients.ActiveDirectory.Platform.dll' |
                    Should -Exist -Because 'that assembly exists only in ADAL 3.x; its absence means a 5.x build slipped in'
            }
        }
    }

    Context 'Task payloads' {

        It 'ships the VstsTaskSdk for every task' {
            foreach ($dir in Get-ChildItem $Impl -Directory) {
                Join-Path $dir.FullName 'ps_modules/VstsTaskSdk' | Should -Exist -Because "task $($dir.Name) cannot call Get-VstsInput without it"
            }
        }

        It 'ships the compiled cmdlet for every cmdlet-backed task' {
            foreach ($task in Get-CmdletBackedTasks) {
                Join-Path $Impl "$task/ps_modules/CI/Innofactor.Crm.CI.dll" | Should -Exist
            }
        }

        It 'ships the lockfile with MinifyJS' {
            # script.ps1 runs npm ci on the agent, which needs the lock present.
            Join-Path $Impl 'MinifyJS/package-lock.json' | Should -Exist
            Join-Path $Impl 'MinifyJS/package.json'      | Should -Exist
        }

        It 'ships the gulpfile MinifyJS actually references' {
            Join-Path $Impl 'MinifyJS/gulpfile.mjs' | Should -Exist
        }
    }

    Context 'Task identity survived packaging' {

        It 'keeps every published task id' {
            foreach ($dir in Get-ChildItem $Impl -Directory) {
                $json  = Read-JsonFile (Join-Path $dir.FullName 'task.json')
                $known = $Baseline.tasks.$($json.name)
                if ($known) {
                    $json.id | Should -BeExactly $known.id -Because "task '$($json.name)' id must never change"
                }
            }
        }

        It 'never lowers a task version' {
            foreach ($dir in Get-ChildItem $Impl -Directory) {
                $json  = Read-JsonFile (Join-Path $dir.FullName 'task.json')
                $known = $Baseline.tasks.$($json.name)
                if ($known) {
                    $v = [version]('{0}.{1}.{2}' -f $json.version.Major, $json.version.Minor, $json.version.Patch)
                    $v | Should -BeGreaterOrEqual ([version]$known.version)
                }
            }
        }
    }
}
