# Releasing

How to publish `InnofactorSE.cinteros-devutils-ci-build-tasks`, and how to get out of trouble
afterwards.

## The two rules

**1. A version number is consumed forever.** Once published, it cannot be re-used, re-uploaded, or
deleted by you. Removing a specific version requires emailing `VSMarketplace@microsoft.com`.
"Unpublish" in the portal pulls the *entire extension*, not one version.

**2. Task versions only ever go up.** Pipelines pin the *major* (`ShuffleExport@9`); the service
resolves minor and patch itself and always serves the **highest registered** version within that
major. A task.json change is invisible unless its version increases, and both the extension
version and the task version must move for an update to take effect.

Rule 2 is what makes a naive rollback fail silently — see below.

---

## Publishing

1. **Clean, then rebuild.** Stale `bin/Release` output is how removed dependencies keep shipping;
   `pack.ps1` copies `*.dll` out of it wholesale.

   ```powershell
   Get-ChildItem Cmdlets -Directory | ForEach-Object {
     foreach ($sub in 'bin','obj') {
       $dir = Join-Path $_.FullName $sub
       if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
     }
   }
   nuget restore Innofactor.Crm.CI.sln
   msbuild Innofactor.Crm.CI.sln /t:Rebuild /p:Configuration=Release
   ```

2. **Bump versions.** `Extension/vss-extension.json`, plus the `task.json` of every task whose
   payload changed. When in doubt bump it — an unnecessary bump is harmless, a missing one means
   the change never reaches anyone.

3. **Package.**

   ```powershell
   .\Extension\pack.ps1        # answer N to "Update revision?" if you set the version by hand,
                               # and N to "Publish extension?" - publish only after steps 4 and 5
   ```

4. **Gate it.** Must be green.

   ```powershell
   .\tests\Run-Tests.ps1 -VsixPath .\Extension\VSIX\<new>.vsix
   ```

5. **Smoke-test against real orgs**, in a **Windows PowerShell 5.1** window - the host an
   agent uses. Use `Test-Connection.ps1`, not `Run-Tests.ps1`: `Install-Module Pester`
   normally lands on the pwsh 7 module path, so 5.1 sees only the inbox Pester 3.4.0 and
   cannot run the Pester suite. `Test-Connection.ps1` needs no test framework.

   Set the connection string with a hidden prompt. Typing `$env:CRM_ONLINE_CONNSTR = '...'`
   directly works too, but saves the secret in PowerShell's history file.

   ```powershell
   # online - this is the run that exercises the ADAL 3.19.8 load path
   # paste e.g. AuthType=ClientSecret;Url=https://...;ClientId=...;ClientSecret=...
   $env:CRM_ONLINE_CONNSTR = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Online connection string' -AsSecureString)))
   .\tests\Test-Connection.ps1

   # on-prem - AD/IFD uses WS-Trust and never loads ADAL, which the script expects
   # paste e.g. AuthType=AD;Url=http://crmserver/org;Domain=...;Username=...;Password=...
   $env:CRM_ONPREM_CONNSTR = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'On-prem connection string' -AsSecureString)))
   .\tests\Test-Connection.ps1 -Target OnPrem
   ```

   Both must pass. Set the connection strings in that window rather than passing them as
   arguments, so they stay out of shell history and process arguments.

   **Close the window afterwards.** That clears the connection strings, and it releases the
   task DLLs `Test-Connection.ps1` loaded from `Extension\Implementation\WhoAmI\ps_modules`.
   .NET Framework cannot unload them, and while they are loaded `pack.ps1` fails with
   "Access to the path ... is denied".

6. **Publish the exact artifact you just tested** — via the
   [publisher portal](https://marketplace.visualstudio.com/manage/publishers/innofactorse)
   (⋯ → Update → drop the `.vsix`), or:

   ```powershell
   tfx extension publish --vsix .\Extension\VSIX\<new>.vsix --token <PAT>
   ```

   The PAT needs **Marketplace → Manage** scope and must be created against **All accessible
   organizations**; an org-scoped token fails with an unhelpful 401.

   Do **not** re-run `pack.ps1` at this point. It rebuilds, so you would publish a package the
   gate never saw.

7. **Commit the version bumps immediately.** The manifest sitting at 9.0.91 while 9.0.95 was live
   is what made "which branch did I publish?" unanswerable for a year.

8. **Refresh the test baseline** so the regression floor tracks reality. Regenerate
   `tests/fixtures/published-baseline.json` from the newly published vsix - its
   `publishedVersion` and per-task ids/versions come straight out of the package. Until
   you do, the *never lowers a task version* check is still anchored to the previous
   release and would not catch a regression between the two.

   Note the manifest and the baseline are legitimately **equal** between releases. The
   gate only requires the manifest not to fall *below* the gallery; the Marketplace
   itself rejects republishing an existing version, so nothing else is needed.

---

## Rolling back

There is no revert button. You roll **forward** with the old code.

### Why the obvious approach fails

Rebuilding the previous release as-is gives it *lower* task versions than the bad release already
registered. The service keeps serving the higher ones, so the publish succeeds and nothing
changes. A correct rollback is **old code, higher version numbers**.

### The recipe

Take the binaries from the last known-good `.vsix` rather than rebuilding from the tag — that way
there is no NuGet, SDK or compiler drift between what worked and what you are restoring.

1. Extract the good package (they are ordinary zips) and the matching source tag:

   ```powershell
   # source tree for manifests and scripts
   git archive backup/IdentityModelConsolidation-pre-sync Extension | tar -x -C <workdir>
   # binaries exactly as shipped
   Expand-Archive .\Extension\VSIX\<good>.vsix -DestinationPath <extracted>
   ```

2. Overlay each task's `ps_modules` from the extracted package onto the source tree.

3. Set `vss-extension.json` to a version above the bad one, and set **every** `task.json` version
   above what the bad release shipped — not back to the old numbers.

4. `tfx extension create`, then run the gate. Expect failures for anything the rollback
   deliberately restores (see below). Everything else must pass — especially *keeps every
   published task id* and *never lowers a task version*.

5. Publish.

### Worked example: rolling 9.0.96 back to 9.0.95

A prepared package already exists at
`Extension/VSIX/InnofactorSE.cinteros-devutils-ci-build-tasks-9.0.97.vsix` — 9.0.95's exact
binaries, renumbered to land above 9.0.96. It is within one byte of the published 9.0.95.

| Task | 9.0.95 | 9.0.96 | rollback 9.0.97 |
| --- | --- | --- | --- |
| ApplyVersionToAssemblies | 9.0.4 | 9.0.5 | **9.0.6** |
| MinifyJS | 8.2.15 | 8.2.16 | **8.2.17** |
| ObfuscateAssembly | 9.0.7 | 9.0.8 | **9.0.9** |
| ShuffleExport | 9.0.12 | 9.0.13 | **9.0.14** |
| ShuffleImport | 9.0.11 | 9.0.12 | **9.0.13** |
| UpdateAssembly | 9.0.7 | 9.0.8 | **9.0.9** |
| UpdatePackage | 9.0.16 | 9.0.17 | **9.0.18** |
| UpdateWebResources | 9.0.9 | 9.0.10 | **9.0.11** |
| WhoAmI | 9.0.7 | 9.0.8 | **9.0.9** |

`Extension/VSIX/` is gitignored, so this package lives only on the machine that built it. Keep a
copy somewhere durable, or rebuild it from the recipe above.

It claims **9.0.97**, so if a normal release takes that number first, renumber the rollback
above whatever is then live - the same version-inversion rule applies.

> **9.0.97 is now taken** by the Shuffle batching release (ShuffleImport 9.0.13, ShuffleExport
> 9.0.14 - the same task numbers the rollback uses). The prepared package above is a rollback to
> 9.0.95 and can no longer be published as it is: renumber every task above its live version, and
> the extension above the live extension, before using it.
>
> **9.0.98** followed (ShuffleImport 9.0.14, ShuffleExport 9.0.15, and a new extension icon), so
> the floor for a renumbered rollback is now ShuffleImport 9.0.15, ShuffleExport 9.0.16 and
> extension 9.0.99.

Running the gate against it fails exactly two assertions, both correct:

- **ships no DotNetZip assembly** — 9.0.95 really did ship `DotNetZip.dll` in four tasks. That is
  what you are restoring.
- **ships the gulpfile MinifyJS references** — 9.0.95 predates the ESM migration and has
  `gulpfile.cjs`, not `gulpfile.mjs`.

### What a rollback costs you

Going back to 9.0.95 also reinstates:

- `DotNetZip.dll` in ShuffleExport, ShuffleImport, UpdateAssembly and UpdateWebResources
  (a HIGH advisory with no patched version — the only fix is removing it)
- the pre-ESM MinifyJS with `gulp-msbuild` and `run-sequence`, and the vulnerable transitive
  dependencies they pull in
- relative image paths in `overview.md`, so the Marketplace screenshots break again

So treat rollback as a way to buy time, not a destination. Fix forward.

---

## If it goes wrong mid-flight

- **Bad version published, not yet widely picked up** — publish the rollback immediately.
  Consumers auto-update on their next pipeline run, so speed matters more than tidiness.
- **Only one task is broken** — you do not have to roll everything back. Publish a new version
  with just that task's payload reverted and its version bumped forward.
- **Extension itself is fine but a consumer is stuck on a cached task** — agents cache task
  packages; a bumped task version is what forces a re-download.
