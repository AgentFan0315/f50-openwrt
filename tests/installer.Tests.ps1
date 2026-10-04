# Tests for install.ps1's own functions, under Windows PowerShell 5.1 and PowerShell 7 (no Pester needed):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\installer.Tests.ps1
# The functions are taken out of install.ps1 with the PowerShell parser and defined here, so the installer itself
# never runs. Exit code: the number of failed checks.
$ErrorActionPreference = 'Stop'
$Top = Split-Path -Parent $PSScriptRoot
$script:failed = 0
$script:passed = 0
function Check($name, $got, $want) {
    if ([string]$got -ceq [string]$want) { $script:passed++ }
    else { $script:failed++; Write-Host "FAIL $name`n  got:  [$got]`n  want: [$want]" -ForegroundColor Red }
}

# the functions under test, straight from install.ps1
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Top "install.ps1"), [ref]$null, [ref]$null)
$want = 'LoadLanguage', 'T', 'NormalizeAnswer', 'Gib', 'ChooseStorage', 'SdState', 'SdKernelOk'
$defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)
foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }
foreach ($w in 'LoadLanguage', 'T', 'NormalizeAnswer') {
    if (-not (Get-Command $w -CommandType Function -ErrorAction SilentlyContinue)) { Write-Host "FAIL: $w not found in install.ps1"; exit 99 }
}
$script:Msg = New-Object 'System.Collections.Generic.Dictionary[string,string]'

# ---- T: every translation, every placeholder --------------------------------------------------------------------
$argsT = 'A1', 'B2', 'C3', 'D4', 'E5', 'F6'
foreach ($lang in 'tr', 'zh') {
    LoadLanguage $lang
    $lines = [IO.File]::ReadAllLines((Join-Path (Join-Path $Top "i18n") "$lang.tsv"), [Text.Encoding]::UTF8)
    foreach ($line in $lines) {
        $i = $line.IndexOf("`t")
        if ($i -le 0 -or $line.StartsWith('#')) { continue }
        $key = $line.Substring(0, $i); $val = $line.Substring($i + 1)
        for ($k = 1; $k -le 6; $k++) { $val = $val.Replace("{$k}", $argsT[$k - 1]) }
        Check "T $lang $key" (T $key @argsT) $val
    }
}
LoadLanguage 'en'
Check 'T english' (T 'device: {1}' 'F50 / MU300') 'device: F50 / MU300'
Check 'T untranslated' (T 'nobody translated {1} {2}' 'x' 'y') 'nobody translated x y'
Check 'T no args' (T 'plain {1}') 'plain {1}'
# the dictionary is case-sensitive: two messages may differ only in case
LoadLanguage 'tr'
Check 'T case' (T 'DEVICE: {1}' 'x') 'DEVICE: x'

# ---- NormalizeAnswer --------------------------------------------------------------------------------------------
$cases = @{
    'evet' = 'yes'; 'e' = 'yes'; 'y' = 'yes'; "$([char]0x662F)" = 'yes'
    ('hay' + [char]0x131 + 'r') = 'no'; 'hayir' = 'no'; 'n' = 'no'; "$([char]0x5426)" = 'no'
    ('g' + [char]0xFC + 'ncelle') = 'update'; 'guncelle' = 'update'; "$([char]0x66F4)$([char]0x65B0)" = 'update'
    'sil' = 'wipe'; 'INSTALL' = 'INSTALL'; 'overwrite' = 'overwrite'; '6.18' = '6.18'
}
foreach ($k in $cases.Keys) { Check "NormalizeAnswer $k" (NormalizeAnswer $k) $cases[$k] }

# ---- Gib (the sizes the free-space check prints) ----------------------------------------------------------------
if (Get-Command Gib -ErrorAction SilentlyContinue) {
    Check 'Gib' ((Gib 34828075008) -replace ',', '.') '32.4 GiB'
}

# ---- ChooseStorage: internal region or SD card -------------------------------------------------------------------
Check 'no card'            (ChooseStorage '' 0 30GB '' '') 'internal'
Check 'card, default'      (ChooseStorage '/dev/block/mmcblk1p1' 62GB 30GB '' '') 'internal'
Check 'card, answer sd'    (ChooseStorage '/dev/block/mmcblk1p1' 62GB 30GB '' 'sd') 'sd'
Check 'small internal'     (ChooseStorage '/dev/block/mmcblk1p1' 62GB 100MB '' '') 'sd'
Check 'forced internal'    (ChooseStorage '/dev/block/mmcblk1p1' 62GB 100MB 'internal' '') 'internal'
Check 'forced sd'          (ChooseStorage '/dev/block/mmcblk1p1' 62GB 30GB 'sd' '') 'sd'
$threw = $false; try { ChooseStorage '' 0 30GB 'sd' '' | Out-Null } catch { $threw = $true }
Check 'forced sd, no card' $threw $true
$threw = $false; try { ChooseStorage '/dev/block/mmcblk1p1' 62GB 30GB '' 'usb' | Out-Null } catch { $threw = $true }
Check 'invalid answer'     $threw $true
$threw = $false; try { ChooseStorage '/dev/block/mmcblk1p1' 62GB 30GB 'usb' '' | Out-Null } catch { $threw = $true }
Check 'invalid forced'     $threw $true

# ---- SdState: what is on the card already (ext4 magic at 1080, label at 1144) -------------------------------------
Check 'sd mu300sd'         (SdState '53ef' 'mu300sd') 'yes'
Check 'sd other label'     (SdState '53ef' 'data') 'foreign'
Check 'sd no label'        (SdState '53ef' '') 'foreign'
Check 'sd root label'      (SdState '53ef' 'mu300root') 'foreign'
Check 'sd not ext4'        (SdState '0000' 'mu300sd') 'no'
Check 'sd unreadable'      (SdState '' '') 'no'

# ---- SdKernelOk: a card installation needs a bundle that lists sdcard in ./features ------------------------------
$kd = Join-Path ([IO.Path]::GetTempPath()) ('mu300-k-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $kd | Out-Null
Check 'sd kernel, no features'      (SdKernelOk 1 $kd) $false
Check 'internal, no features'       (SdKernelOk 0 $kd) $true
[IO.File]::WriteAllText((Join-Path $kd 'features'), "other`n")
Check 'sd kernel, other features'   (SdKernelOk 1 $kd) $false
[IO.File]::WriteAllText((Join-Path $kd 'features'), "sdcard`n")
Check 'sd kernel, sdcard'           (SdKernelOk 1 $kd) $true
Remove-Item -Recurse -Force $kd
$src = [IO.File]::ReadAllText((Join-Path $Top 'install.ps1'))
$iUnpack = $src.IndexOf('& tar -xzf "$REL\mu300-kernel-$KERNEL.tar.gz" -C $KMAIN')
$iCheck = $src.IndexOf('if (-not (SdKernelOk $SD_MODE $KMAIN))')
Check 'sd kernel check after unpack' ($iUnpack -ge 0 -and $iCheck -gt $iUnpack) $true

# ---- uninstall.ps1: what is on the card, and the command that erases it -----------------------------------------
$uast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Top "uninstall.ps1"), [ref]$null, [ref]$null)
$udefs = $uast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and @('SdState', 'SdEraseCommand') -contains $n.Name }, $true)
foreach ($d in $udefs) { . ([scriptblock]::Create($d.Extent.Text)) }
Check 'uninstall sd mu300sd'    (SdState '53ef' 'mu300sd') 'yes'
Check 'uninstall sd other'      (SdState '53ef' 'mu300root') 'foreign'
Check 'uninstall sd not ext4'   (SdState '0000' 'mu300sd') 'no'
foreach ($dev in '/dev/block/mmcblk0p1', '/dev/block/mmcblk0', '/dev/block/sda1', '/dev/block/mmcblk1p1 x', '') {
    $threw = $false; try { SdEraseCommand $dev | Out-Null } catch { $threw = $true }
    Check "erase refuses [$dev]" $threw $true
}
$cmd = SdEraseCommand '/dev/block/mmcblk1p1'
Check 'erase command quotes'    ($cmd -match "[`"']") $false
Check 'erase command target'    ($cmd -match ' of=/dev/block/mmcblk1p1 bs=1048576 count=64 ') $true
# the same text tools/storage.sh's sd_erase_cmd builds (and tests/test_installer.py runs against stubs)
if (Get-Command sh -CommandType Application -ErrorAction SilentlyContinue) {
    foreach ($dev in '/dev/block/mmcblk1p1', '/dev/block/mmcblk1') {
        $shCmd = (& sh -c ('unset MU300_SYSFS MU300_MOUNTS; . ./tools/storage.sh; sd_erase_cmd ' + $dev)) -join "`n"
        Check "erase command = storage.sh ($dev)" (SdEraseCommand $dev) $shCmd
    }
}

Write-Host "$script:passed passed, $script:failed failed"
exit $script:failed
