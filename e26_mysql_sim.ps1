<#
  e26_mysql_sim.ps1 - replicate InnoDB's Windows dir-flush call sites and
  measure the per-operation cost of the three flush variants.

  MySQL's real build is out of budget for a CI runner, so this harness
  reproduces the exact Win32 op shapes of os_parent_dir_fsync_win()'s six
  call sites (mkdir, create, delete, rename) and times them with:
    none  - no flush                     (upstream Windows behavior)
    dir   - FlushFileBuffers(parent dir) (PR #895 commit 1)
    root  - parent + volume root         (PR #895 head, commit 9eb979ae)

  Usage: pwsh -File e26_mysql_sim.ps1 -Volume D: -Iters 200 -Rounds 3
#>
param(
  [string]$Volume = 'D:',
  [int]$Iters = 200,
  [int]$Warmup = 20
)
$ErrorActionPreference = 'Stop'

if (-not ('E26M' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class E26M {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string name, uint access, uint share,
      IntPtr sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool WriteFile(IntPtr h, byte[] buf, int n, out int written, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool FlushFileBuffers(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool DeleteFileW(string name);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool CreateDirectoryW(string name, IntPtr sa);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool RemoveDirectoryW(string name);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool MoveFileW(string from, string to);
}
'@
}
$GENERIC_WRITE = 0x40000000
$workDir = Join-Path $Volume 'e26mysql'

if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Force -Path $workDir | Out-Null }

function Flush-Variant {
  param([string]$Variant, [string]$Dir, [string]$Root)
  if ($Variant -eq 'none') { return }
  $h = [E26M]::CreateFileW($Dir, $GENERIC_WRITE, 7, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
  if ($h.ToInt64() -eq -1) { throw "open dir $Dir failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
  [void][E26M]::FlushFileBuffers($h)
  [void][E26M]::CloseHandle($h)
  if ($Variant -eq 'root') {
    $r = [E26M]::CreateFileW($Root, $GENERIC_WRITE, 7, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
    if ($r.ToInt64() -eq -1) { throw "open root failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    [void][E26M]::FlushFileBuffers($r)
    [void][E26M]::CloseHandle($r)
  }
}

# Phase 1: mkdir + rmdir (os_file_create_directory call site)
# Phase 2: create + delete file (os_file_create_func O_CREAT / delete sites)
# Phase 3: rename (os_file_rename_func, MOVEFILE_WRITE_THROUGH in MySQL)
function Do-Phase {
  param([string]$Variant, [int]$Phase, [int]$N)
  $root = $Volume + '\'
  for ($i = 0; $i -lt $N; $i++) {
    if ($Phase -eq 1) {
      $sub = Join-Path $workDir ("p1_{0}_{1}" -f $Variant, $i)
      [void][E26M]::CreateDirectoryW($sub, [IntPtr]::Zero)
      Flush-Variant -Variant $Variant -Dir $workDir -Root $root
      [void][E26M]::RemoveDirectoryW($sub)
      Flush-Variant -Variant $Variant -Dir $workDir -Root $root
    } elseif ($Phase -eq 2) {
      $f = Join-Path $workDir ("p2_{0}_{1}.tmp" -f $Variant, $i)
      $h = [E26M]::CreateFileW($f, $GENERIC_WRITE, 0, [IntPtr]::Zero, 2, 0, [IntPtr]::Zero)
      if ($h.ToInt64() -eq -1) { throw "create $f failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
      $buf = [Text.Encoding]::ASCII.GetBytes(('M' * 2048))
      $w = 0
      [void][E26M]::WriteFile($h, $buf, 2048, [ref]$w, [IntPtr]::Zero)
      [void][E26M]::CloseHandle($h)
      Flush-Variant -Variant $Variant -Dir $workDir -Root $root
      [void][E26M]::DeleteFileW($f)
      Flush-Variant -Variant $Variant -Dir $workDir -Root $root
    } else {
      $a = Join-Path $workDir ("p3_{0}_{1}.tmp" -f $Variant, $i)
      $b = Join-Path $workDir ("p3_{0}_{1}.new" -f $Variant, $i)
      $h = [E26M]::CreateFileW($a, $GENERIC_WRITE, 0, [IntPtr]::Zero, 2, 0, [IntPtr]::Zero)
      if ($h.ToInt64() -eq -1) { throw "create $a failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
      $buf = [Text.Encoding]::ASCII.GetBytes(('R' * 2048))
      $w = 0
      [void][E26M]::WriteFile($h, $buf, 2048, [ref]$w, [IntPtr]::Zero)
      [void][E26M]::CloseHandle($h)
      [void][E26M]::MoveFileW($a, $b)
      Flush-Variant -Variant $Variant -Dir $workDir -Root $root
      [void][E26M]::DeleteFileW($b)
    }
  }
}

Write-Host "=== E26 MySQL-shaped flush sim: volume $Volume, $Iters iters x 3 rounds ==="
foreach ($phase in 1..3) {
  $res = @()
  foreach ($variant in 'none','dir','root') {
    Do-Phase -Variant $variant -Phase $phase -N $Warmup
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Do-Phase -Variant $variant -Phase $phase -N $Iters
    $sw.Stop()
    $ms = [math]::Round($sw.Elapsed.TotalMilliseconds / $Iters, 4)
    $res += [pscustomobject]@{ V = $variant; Ms = $ms }
    Write-Host ("  phase{0} {1,-5}: {2} ms/op" -f $phase, $variant, $ms)
  }
  $d = [math]::Round(($res | Where-Object V -eq 'dir').Ms - ($res | Where-Object V -eq 'none').Ms, 4)
  $r = [math]::Round(($res | Where-Object V -eq 'root').Ms - ($res | Where-Object V -eq 'none').Ms, 4)
  Write-Host ("  phase{0} delta: dir +{1} ms/op | root +{2} ms/op" -f $phase, $d, $r)
}
# clean leftovers
Get-ChildItem $workDir -Filter 'p*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
