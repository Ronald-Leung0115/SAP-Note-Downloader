<#
  sap_note_download.ps1  (SAP Note Downloader v9.4 EN)
  Batch-download SAP Note files from SAP for Me (me.sap.com) with your own S-user.
  Nothing to install (no Python etc.): uses built-in Windows PowerShell + Google Chrome.

  First run:
    double-click Run_SAP_Note_Download.bat
    -> enter S-user and password (encrypted with Windows DPAPI in .sap_credential.xml;
       only your Windows account on this PC can decrypt it)
    -> pick a txt file (one note number per line); press Cancel to type them instead
  Afterwards: logs in automatically; if SAP asks for MFA, complete it in the Chrome window.

  Email with several S-users: the first time SAP shows "Account selection", you pick the
  account here in this window; the choice is saved in .sap_account.txt and reused.

  Several notes are downloaded at the same time in separate Chrome windows (default 3).
  Change it with e.g.  Run_SAP_Note_Download.bat -Windows 1

  Change password / account: double-click Reset_Login.bat
#>
param(
    [string[]]$Notes,
    [string]$NotesFile,
    [string]$OutDir,
    [double]$Delay = 3,
    [ValidateRange(1, 6)][int]$Windows = 3,   # Chrome windows downloading at the same time
    [switch]$ResetCredential
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$AppVersion = '9.4 EN'
Write-Host "SAP Note Downloader v$AppVersion"

$BaseDir    = $PSScriptRoot
$ProfileDir = Join-Path $BaseDir '.sap_profile'
$CredFile   = Join-Path $BaseDir '.sap_credential.xml'
$AccountFile = Join-Path $BaseDir '.sap_account.txt'     # S-user chosen on the "Account selection" page
$HomeUrl    = 'https://me.sap.com/'
$NoteUrl    = 'https://me.sap.com/notes/{0}'
if (-not $OutDir) { $OutDir = Join-Path $BaseDir 'sap_notes' }
$DebugDir   = Join-Path $OutDir '_debug'

# ------------------------------------------------------------------
# S-user credentials (DPAPI encrypted)
# ------------------------------------------------------------------
if ($ResetCredential) {
    foreach ($f in $CredFile, $AccountFile) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
}
$Cred = $null
if (Test-Path -LiteralPath $CredFile) {
    try { $Cred = Import-Clixml -LiteralPath $CredFile }
    catch { Write-Host 'Cannot read saved credentials (different PC or Windows account?). Please enter them again.' }
}
if (-not $Cred) {
    Write-Host ''
    Write-Host '=== Set up S-user credentials (one time only, stored encrypted) ==='
    $u = (Read-Host 'S-user (e.g. S0012345678 or email)').Trim()
    $p = Read-Host 'Password' -AsSecureString
    if (-not $u -or $p.Length -eq 0) { throw 'S-user and password must not be empty' }
    $Cred = New-Object System.Management.Automation.PSCredential($u, $p)
    $Cred | Export-Clixml -LiteralPath $CredFile
    Write-Host "Saved: $CredFile"
}
if ($ResetCredential) {
    Write-Host 'Credentials updated.'
    return
}

New-Item -ItemType Directory -Force -Path $OutDir, $DebugDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

# ------------------------------------------------------------------
# Read note numbers
# ------------------------------------------------------------------
# File dialog to pick a txt file; returns $null on Cancel
function Select-NotesFile {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }   # keep the dialog on top
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Select a txt file with SAP Note numbers (one per line)'
        $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        $dlg.InitialDirectory = $BaseDir
        if (Test-Path (Join-Path $BaseDir 'notes.txt')) { $dlg.FileName = 'notes.txt' }
        $ok = $dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK
        $owner.Dispose()
        if ($ok) { return $dlg.FileName }
    } catch {
        Write-Host "(Cannot open file dialog: $($_.Exception.Message))"
    }
    return $null
}

$raw = @()
if ($Notes) { $raw += $Notes }
if (-not $raw -and -not $NotesFile) {
    Write-Host ''
    Write-Host 'Select the txt file with note numbers in the dialog (Cancel = type them instead)...'
    $NotesFile = Select-NotesFile
}
if ($NotesFile) {
    Write-Host "Reading $NotesFile"
    $raw += Get-Content -LiteralPath $NotesFile -Encoding UTF8 |
            ForEach-Object { ($_ -split '#')[0] }
}
function ConvertTo-NoteList($raw) {
    $l = New-Object System.Collections.Generic.List[string]
    foreach ($item in ($raw -join ' ') -split '[\s,;]+') {
        $n = ($item -replace '\D', '').TrimStart('0')
        if ($n -and -not $l.Contains($n)) { $l.Add($n) }
    }
    return , $l
}
$list = ConvertTo-NoteList $raw
if ($list.Count -eq 0) {
    if ($NotesFile) { Write-Host 'No valid note numbers found in the txt file.' }
    elseif (-not $Notes) { Write-Host 'No txt file selected.' }
}
# No file / dialog closed / file has no notes -> ask to type until we get valid note numbers
while ($list.Count -eq 0) {
    $typed = Read-Host 'Enter note numbers (separated by spaces or commas)'
    $list = ConvertTo-NoteList $typed
    if ($list.Count -eq 0) { Write-Host 'No valid note number, please try again.' }
}
Write-Host "$($list.Count) note(s): $($list -join ', ')"

# ------------------------------------------------------------------
# Find Chrome (fall back to Edge)
# ------------------------------------------------------------------
$chromePaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
)
$edgePaths = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
)
$browserExe = $chromePaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $browserExe) {
    $browserExe = $edgePaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($browserExe) { Write-Host 'Chrome not found, using Edge.' }
}
if (-not $browserExe) { throw 'Chrome (or Edge) not found, please install Google Chrome' }
Write-Host "Browser: $browserExe"

# Pick a free port for browser remote debugging
$l = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$l.Start(); $Port = $l.LocalEndpoint.Port; $l.Stop()

# ------------------------------------------------------------------
# Chrome DevTools Protocol (CDP) helpers
# ------------------------------------------------------------------
$script:cdpId = 0

function Connect-Cdp([string]$wsUrl) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
    $ws.Options.Proxy = $null   # local browser: bypass corporate proxy
    $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait()
    return $ws
}

$script:wsBuf = @{}
$script:wsPending = @{}

function Receive-CdpMessage($ws, [double]$timeoutSec) {
    $key = $ws.GetHashCode()
    if (-not $script:wsBuf.ContainsKey($key)) { $script:wsBuf[$key] = New-Object byte[] 1048576 }
    $buf = $script:wsBuf[$key]
    $ms = New-Object System.IO.MemoryStream
    do {
        if ($script:wsPending.ContainsKey($key)) {
            $task = $script:wsPending[$key]; $script:wsPending.Remove($key)
        } else {
            $rseg = New-Object System.ArraySegment[byte] -ArgumentList (, $buf)
            $task = $ws.ReceiveAsync($rseg, [Threading.CancellationToken]::None)
        }
        if (-not $task.Wait([TimeSpan]::FromSeconds([Math]::Max(0.1, $timeoutSec)))) {
            $script:wsPending[$key] = $task      # keep waiting next time; never start a second ReceiveAsync
            return $null
        }
        $ms.Write($buf, 0, $task.Result.Count)
    } while (-not $task.Result.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($ms.ToArray())
}

function Invoke-Cdp($ws, [string]$method, $params = @{}, [int]$timeoutSec = 60) {
    $script:cdpId++
    $id = $script:cdpId
    $json = @{ id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList (, $bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
                  [Threading.CancellationToken]::None).Wait()

    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $raw = Receive-CdpMessage $ws ($deadline - (Get-Date)).TotalSeconds
        if ($null -eq $raw) { break }
        try { $msg = $raw | ConvertFrom-Json } catch { continue }
        if ($msg.id -eq $id) {
            if ($msg.error) { throw "CDP error ($method): $($msg.error.message)" }
            return $msg.result
        }
        # ignore other events / stale responses
    }
    throw "CDP timeout: $method"
}

function Get-LocalJson([string]$url) {
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = $null           # local address: bypass proxy
    $wc.Encoding = [Text.Encoding]::UTF8
    try { return ($wc.DownloadString($url) | ConvertFrom-Json) } finally { $wc.Dispose() }
}

function Invoke-Js($ws, [string]$js) {
    $r = Invoke-Cdp $ws 'Runtime.evaluate' @{ expression = $js; returnByValue = $true }
    return $r.result.value
}

function Save-Screenshot($ws, [string]$path) {
    try {
        $r = Invoke-Cdp $ws 'Page.captureScreenshot' @{ format = 'png' }
        [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($r.data))
    } catch { }
}

# ------------------------------------------------------------------
# Auto login (SAP ID Service: user first, then password; MFA is manual)
# ------------------------------------------------------------------
$LoginStepJs = @'
(function (user, pass, allowPw) {
  var isLogin = /accounts\d*\.(sap|ondemand)\.com$/i.test(location.hostname) ||
                /\/saml2?\//i.test(location.pathname);
  function vis(e) { return e && e.getClientRects().length > 0 && !e.disabled; }
  function first(sel) {
    var l = document.querySelectorAll(sel);
    for (var i = 0; i < l.length; i++) { if (vis(l[i])) return l[i]; }
    return null;
  }
  if (!isLogin) {
    if (document.readyState !== 'complete') return 'loading';
    // SAP for Me may only show a Log On button when logged out
    var els = document.querySelectorAll('button,[role=button],ui5-button,a');
    for (var k = 0; k < els.length; k++) {
      var t = (els[k].innerText || els[k].textContent || '').trim();
      if (/^(log ?on|log ?in|sign ?in)$/i.test(t) && vis(els[k])) { els[k].click(); return 'logon-clicked'; }
    }
    return 'app';
  }
  function setVal(el, v) {
    var d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    d.set.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }
  function submit(el) {
    var b = first('#logOnFormSubmit, button[type=submit], input[type=submit]');
    if (b) { b.click(); return; }
    if (el.form) { if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit(); }
  }
  if (window.__sapAccounts && window.__sapAccounts().length >= 2) return 'accounts';
  var userEl = first('#j_username, input[name=j_username], input[type=email], input[autocomplete=username], input[name=username]');
  var pwEl = first('input[type=password]');
  if (pwEl) {
    if (!allowPw) return 'pw-again';
    if (userEl && !userEl.value) setVal(userEl, user);
    setVal(pwEl, pass);
    submit(pwEl);
    return 'pw-sent';
  }
  if (userEl) {
    if (userEl.value !== user) setVal(userEl, user);
    submit(userEl);
    return 'user-sent';
  }
  return 'other';   // e.g. MFA / passcode page
})(__ARGS__)
'@

# "Account selection" page (one email with several S-users)
#   list          -> JSON [{id, label}]
#   pick:<S-user> -> 'T|x|y' centre of that account entry (clicked with the real mouse)
#   continue      -> 'T|x|y' of a Continue / Next button, or 'none'
$AccountJs = @'
(function (mode) {
  function vis(e) { var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; }
  function txt(e) { return (e.innerText || e.textContent || '').replace(/\s+/g, ' ').trim(); }
  function ids(t) {
    var m = t.match(/\bS\d{8,11}\b/gi) || [], u = [];
    m.forEach(function (x) { x = x.toUpperCase(); if (u.indexOf(x) < 0) u.push(x); });
    return u;
  }
  // an entry = the largest element that contains exactly one S-user id
  window.__sapAccounts = function () {
    var out = [], seen = {}, all = document.querySelectorAll('body *');
    for (var i = 0; i < all.length; i++) {
      var e = all[i];
      if (/^(SCRIPT|STYLE|INPUT|OPTION)$/.test(e.tagName) || !vis(e)) continue;
      var my = ids(txt(e));
      if (my.length !== 1 || seen[my[0]]) continue;
      var p = e.parentElement;
      if (p && ids(txt(p)).length === 1) continue;       // parent is still the same entry
      seen[my[0]] = 1;
      out.push({ id: my[0], label: txt(e).slice(0, 120), el: e });
    }
    return out;
  };
  function target(e) {
    try { e.scrollIntoView({ block: 'center' }); } catch (x) {}
    var r = e.getBoundingClientRect();
    return 'T|' + Math.round(r.left + Math.min(r.width / 2, 120)) + '|' + Math.round(r.top + r.height / 2);
  }
  if (mode === 'init') return '';
  var acc = window.__sapAccounts();
  if (mode === 'list') return JSON.stringify(acc.map(function (a) { return { id: a.id, label: a.label }; }));
  if (mode.indexOf('pick:') === 0) {
    var want = mode.slice(5).toUpperCase();
    for (var i = 0; i < acc.length; i++) if (acc[i].id === want) return target(acc[i].el);
    return 'not-found';
  }
  if (mode === 'continue') {
    var b = document.querySelectorAll('button,input[type=submit],[role=button],a');
    for (var k = 0; k < b.length; k++) {
      if (vis(b[k]) && !b[k].disabled && /^(continue|next|select|ok)$/i.test(txt(b[k]) || b[k].value || '')) return target(b[k]);
    }
    return 'none';
  }
  return '';
})('__MODE__')
'@

function Invoke-AccountJs($ws, [string]$mode) {
    return Invoke-Js $ws ($AccountJs.Replace('__MODE__', $mode))
}

# Pick the S-user on the "Account selection" page; asks once and saves the choice
function Select-SapAccount($ws) {
    # assign first: Windows PowerShell 5.1 returns a JSON array as ONE object from the pipeline
    $parsed = (Invoke-AccountJs $ws 'list') | ConvertFrom-Json
    $accs = @($parsed | ForEach-Object { $_ })
    if ($accs.Count -eq 0) { return $false }
    $want = ''
    if (Test-Path -LiteralPath $AccountFile) { $want = ([IO.File]::ReadAllText($AccountFile)).Trim().ToUpper() }
    if (-not $want -or -not ($accs | Where-Object { $_.id -eq $want })) {
        if ($want) { Write-Host "Saved account $want is not in the list." }
        Write-Host ''
        Write-Host '=== This email has several S-user accounts. Which one should be used? ==='
        for ($i = 0; $i -lt $accs.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $accs[$i].label) }
        while ($true) {
            $ans = (Read-Host "Enter 1-$($accs.Count) (or the S-user id)").Trim().ToUpper()
            $n = 0
            if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $accs.Count) { $want = $accs[$n - 1].id; break }
            if ($accs | Where-Object { $_.id -eq $ans }) { $want = $ans; break }
            Write-Host 'Invalid choice, please try again.'
        }
        [IO.File]::WriteAllText($AccountFile, $want)
        Write-Host "Saved account choice: $want (Reset_Login.bat clears it)"
    }
    $r = Invoke-AccountJs $ws "pick:$want"
    if ($r -notlike 'T|*') { return $false }
    Start-Sleep -Milliseconds 300
    $parts = $r.Split('|')
    Invoke-RealClick ([double]$parts[1]) ([double]$parts[2]) $ws
    Write-Host "Selected account $want."
    Start-Sleep -Seconds 2
    # some versions need a Continue button after selecting
    try {
        if ((Invoke-Js $ws ($LoginStepJs.Replace('__ARGS__', '"","",false'))) -eq 'accounts') {
            $c = Invoke-AccountJs $ws 'continue'
            if ($c -like 'T|*') { $cp = $c.Split('|'); Invoke-RealClick ([double]$cp[1]) ([double]$cp[2]) $ws }
        }
    } catch { }
    return $true
}

function Test-LoggedIn($ws) {
    $s = Invoke-Js $ws ($LoginStepJs.Replace('__ARGS__', '"","",false'))
    return ($s -eq 'app')
}

function Invoke-AutoLogin($ws, [string]$startUrl) {
    if ($startUrl) { try { Invoke-Cdp $ws 'Page.navigate' @{ url = $startUrl } 30 | Out-Null } catch { } }

    $user  = $Cred.UserName
    $plain = $Cred.GetNetworkCredential().Password
    $pwSentAt = $null; $userSent = 0; $appCount = 0; $otherSince = $null; $giveUp = $false; $accTries = 0
    $start = Get-Date

    try {
        while (((Get-Date) - $start).TotalSeconds -lt 120) {
            Start-Sleep -Seconds 1
            $allowPw = if ($pwSentAt) { 'false' } else { 'true' }   # send the password at most once to avoid locking the account
            $jsArgs = (ConvertTo-Json $user) + ',' + (ConvertTo-Json $plain) + ',' + $allowPw
            try {
                Invoke-AccountJs $ws 'init' | Out-Null      # defines window.__sapAccounts for LoginStepJs
                $s = Invoke-Js $ws ($LoginStepJs.Replace('__ARGS__', $jsArgs))
            }
            catch { continue }   # page is navigating, retry next second

            switch ($s) {
                'app' {
                    $appCount++
                    if ($appCount -ge 3) { Write-Host 'Logged in to SAP for Me.'; return $true }
                }
                'loading'       { $appCount = 0 }
                'accounts' {
                    $appCount = 0; $accTries++
                    if ($accTries -gt 3) {
                        Write-Host 'Could not select the account automatically.'; $giveUp = $true
                    } elseif (-not (Select-SapAccount $ws)) {
                        Write-Host 'Could not read the account list.'; $giveUp = $true
                    }
                }
                'logon-clicked' { $appCount = 0; Start-Sleep -Seconds 2 }
                'user-sent' {
                    $appCount = 0; $userSent++
                    if ($userSent -gt 3) { Write-Host 'The S-user does not seem to be accepted.'; $giveUp = $true }
                    Start-Sleep -Seconds 2
                }
                'pw-sent' {
                    $appCount = 0; $pwSentAt = Get-Date
                    Write-Host 'Entered S-user and password automatically...'
                    Start-Sleep -Seconds 3
                }
                'pw-again' {
                    $appCount = 0
                    if (((Get-Date) - $pwSentAt).TotalSeconds -gt 15) {
                        Write-Host ''
                        Write-Host '!!! Login failed, the password may be wrong. Not retrying automatically to avoid locking the account.'
                        Write-Host '!!! Please run Reset_Login.bat to set the password again.'
                        $giveUp = $true
                    }
                }
                'other' {
                    $appCount = 0
                    if (-not $otherSince) { $otherSince = Get-Date }
                    if (((Get-Date) - $otherSince).TotalSeconds -gt 5) {
                        Write-Host ''
                        Write-Host '>>> SAP requires additional verification (e.g. MFA). Please complete it in the Chrome window.'
                        Read-Host  '>>> When done, come back here and press Enter' | Out-Null
                        $otherSince = $null; $start = Get-Date
                    }
                }
            }
            if ($s -ne 'other') { $otherSince = $null }
            if ($giveUp) { break }
        }
    } finally {
        $plain = $null
    }

    # Auto login failed -> let the user log in manually
    Write-Host ''
    Write-Host '>>> Auto login did not complete. Please log in manually in the Chrome window.'
    Read-Host  '>>> Once you see the SAP for Me home page, come back here and press Enter' | Out-Null
    Start-Sleep -Seconds 2
    return (Test-LoggedIn $ws)
}

# ------------------------------------------------------------------
# Download one note
# ------------------------------------------------------------------
# One JS snippet with several modes: find / find-more / dialog / dump
# Searches shadow DOM and same-origin iframes, and recognises icon-only buttons
$NotePageJs = @'
(function (mode, num) {
  if (/accounts\d*\.(sap|ondemand)\.com$/i.test(location.hostname) ||
      /\/saml2?\//i.test(location.pathname)) return 'login';
  if (num && mode !== 'dump' && location.href.indexOf(num) < 0) return 'wrong-page';

  function allElements() {
    var out = [], stack = [document], frames = 0;
    while (stack.length) {
      var root = stack.pop(), els;
      try { els = root.querySelectorAll('*'); } catch (e) { continue; }
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        out.push(el);
        if (el.shadowRoot) stack.push(el.shadowRoot);
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
          frames++;
          try { if (el.contentDocument) stack.push(el.contentDocument); } catch (e) {}
        }
      }
    }
    out.frames = frames;
    return out;
  }
  function visible(e) { try { return e.getClientRects().length > 0; } catch (x) { return false; } }
  function attr(e, n) { return (e.getAttribute && e.getAttribute(n)) || ''; }
  function cls(e) { return typeof e.className === 'string' ? e.className : ''; }
  function labelledBy(e) {
    var ids = attr(e, 'aria-labelledby'); if (!ids) return '';
    var root = e.getRootNode ? e.getRootNode() : document, t = [];
    ids.split(/\s+/).forEach(function (id) {
      var x = (root.getElementById && root.getElementById(id)) || document.getElementById(id);
      if (x) t.push(x.textContent);
    });
    return t.join(' ');
  }
  function iconOf(e) {
    var parts = [attr(e, 'icon')];
    var lists = [];
    if (e.querySelectorAll) lists.push(e.querySelectorAll('[icon],[name],[aria-label],[data-sap-ui-icon-content]'));
    if (e.shadowRoot) lists.push(e.shadowRoot.querySelectorAll('[icon],[name],[aria-label]'));
    lists.forEach(function (l) {
      for (var i = 0; i < l.length && i < 6; i++) parts.push(attr(l[i], 'icon'), attr(l[i], 'name'), attr(l[i], 'aria-label'));
    });
    return parts.join(' ').replace(/\s+/g, ' ').trim();
  }
  function describe(e) {
    return {
      tag: e.tagName.toLowerCase(), id: e.id || '',
      text: (e.innerText || e.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80),
      aria: attr(e, 'aria-label'), title: attr(e, 'title'), tooltip: attr(e, 'tooltip'),
      accName: attr(e, 'accessible-name'), labelledBy: labelledBy(e).replace(/\s+/g, ' ').trim().slice(0, 80),
      icon: iconOf(e).slice(0, 120), cls: cls(e).slice(0, 80)
    };
  }
  function isClickable(e) {
    var t = e.tagName;
    if (t === 'BUTTON' || t === 'A') return true;
    if (/^(button|menuitem|link)$/i.test(attr(e, 'role'))) return true;
    if (/^UI5-.*(BUTTON|MENU-ITEM|LINK)/.test(t)) return true;
    return /\bsapMBtn\b/.test(cls(e)) && t !== 'SPAN';
  }

  // Return the element centre (incl. iframe offsets); PowerShell does a real mouse click
  function target(e, kind) {
    try { e.scrollIntoView({ block: 'center' }); } catch (x) {}
    var r = e.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
    // Covered by a loading overlay or something else -> not clickable yet
    var root = e.getRootNode ? e.getRootNode() : document, hit = null;
    try { hit = root.elementFromPoint ? root.elementFromPoint(x, y) : e.ownerDocument.elementFromPoint(x, y); } catch (q) {}
    if (hit && hit !== e && !e.contains(hit) && !hit.contains(e)) return 'covered';
    var w = e.ownerDocument.defaultView;
    while (w && w.frameElement) {
      var f = w.frameElement, fr = f.getBoundingClientRect();
      x += fr.left + f.clientLeft; y += fr.top + f.clientTop;
      w = w.parent;
    }
    var d = describe(e);
    var desc = (d.tag + ' ' + [d.text, d.aria, d.title, d.tooltip, d.icon].filter(Boolean).join(' / ')).slice(0, 70);
    return 'T|' + Math.round(x) + '|' + Math.round(y) + '|' + kind + '|' + desc.replace(/\|/g, '/');
  }

  var els = allElements(), cands = [];
  for (var i = 0; i < els.length; i++) if (isClickable(els[i]) && visible(els[i])) cands.push(els[i]);

  // Loading indicators that cover a big part of the window (small ones inside a section are ignored)
  var busySel = '.sapUiLocalBusyIndicator,.sapMBusyIndicator,.sapUiBlockLayer,ui5-busy-indicator[active]';
  function busyList(all) {
    var out = [], area = Math.max(1, window.innerWidth * window.innerHeight);
    for (var b = 0; b < els.length; b++) {
      var e = els[b];
      try {
        if (!e.matches || !e.matches(busySel) || !visible(e)) continue;
        var r = e.getBoundingClientRect(), share = (r.width * r.height) / area;
        if (all || share > 0.3) out.push({ id: e.id || '', cls: cls(e).slice(0, 60), share: Math.round(share * 100) + '%' });
      } catch (q) {}
    }
    return out;
  }

  if (mode === 'dump') {
    return JSON.stringify({ url: location.href, size: window.innerWidth + 'x' + window.innerHeight,
                            frames: els.frames, busy: busyList(true), buttons: cands.map(describe) }, null, 1);
  }

  var bad = /pdf|change|attach|software|print|share|mail|favou?rite|feedback|basket/i;

  // find      : page must not be loading
  // find-more : same, and may open the "..." (More) menu
  // find-loose: ignore loading indicators, may open the More menu
  if (mode === 'find' || mode === 'find-more') {
    if (document.readyState !== 'complete') return 'busy';
    if (busyList(false).length) return 'busy';
  }

  if (mode === 'dialog') {
    var dlgSel = '[role=dialog],[role=alertdialog],ui5-dialog,ui5-popover,.sapMDialog,.sapMPopover';
    for (var d = 0; d < cands.length; d++) {
      var c = cands[d], inDlg = c.closest && c.closest(dlgSel);
      if (!inDlg) { var rn = c.getRootNode && c.getRootNode(); if (rn && rn.host && rn.host.closest) inDlg = rn.host.closest(dlgSel); }
      if (!inDlg) continue;
      var ld = describe(c), tx = [ld.text, ld.aria, ld.title, ld.tooltip, ld.icon].join(' ');
      if (/download|^\s*ok\s*$|continue|confirm/i.test(tx) && !/cancel|close|pdf/i.test(tx)) {
        return target(c, 'dialog');
      }
    }
    return 'no-dialog';
  }

  function score(e) {
    var d = describe(e), labels = [d.text, d.aria, d.title, d.tooltip, d.accName, d.labelledBy];
    for (var k = 0; k < labels.length; k++) {
      if (/^\s*download(\s+(sap\s+)?note|\s+for\s+snote)?\s*$/i.test(labels[k])) return 3;
    }
    var all = labels.join(' | ');
    if (/(^|[\s\/])download($|\s)/i.test(d.icon) && !bad.test(all)) return 2;   // icon-only button
    if (/download/i.test(all) && !bad.test(all) && d.text.length < 40) return 1;
    return 0;
  }
  var best = null, bestScore = 0;
  for (var m = 0; m < cands.length; m++) {
    var s = score(cands[m]);
    if (s > bestScore) { best = cands[m]; bestScore = s; }
  }
  if (best) return target(best, 'download');

  if (mode === 'find-more' || mode === 'find-loose') {
    // a menu / popover is already open -> wait for its items instead of closing it again
    var pops = document.querySelectorAll('.sapMPopover,.sapMActionSheet,[role=menu],ui5-popover[open],ui5-menu[open]');
    for (var q2 = 0; q2 < pops.length; q2++) if (visible(pops[q2])) return 'menu-open';
    // the note's own "..." button (ObjectPage header) first, then other real More buttons;
    // skip hidden helper elements (e.g. the breadcrumb's invisible select) and tab-bar overflows
    var skip = /sapUiPseudoInvisibleText|sapMTBHiddenElement|sapMSltHiddenSelect|sapMITB|sapFShellBar/;
    var bestMore = null, bestRank = 0;
    for (var n = 0; n < cands.length; n++) {
      var ce = cands[n], dd = describe(ce), a2 = [dd.text, dd.aria, dd.title, dd.tooltip, dd.icon].join(' ');
      if (!/(^|\s)(more|overflow|more options|additional options)(\s|$)/i.test(a2)) continue;
      if (skip.test(dd.cls) || /breadcrumb/i.test(dd.id)) continue;
      var rr = ce.getBoundingClientRect();
      if (rr.width < 8 || rr.height < 8) continue;
      var rank = /ObjectPageHeader-overflow/i.test(dd.id) ? 3 : (/overflow/i.test(dd.id) ? 2 : 1);
      if (rank > bestRank) { bestMore = ce; bestRank = rank; }
    }
    if (bestMore) return target(bestMore, 'more');
  }
  return 'wait';
})('__MODE__', '__NUM__')
'@

# ------------------------------------------------------------------
# Downloads (shared by all windows)
# Chrome saves each download as <guid> (behavior 'allowAndName'); when it completes we rename it
# to its real name. This way every file is matched to the window / note that started it.
# ------------------------------------------------------------------
$script:downloads = @{}      # guid -> @{ frameId; name; state; owner }
function Update-DownloadState {
    while ($true) {
        $raw = Receive-CdpMessage $browserWs 0.1
        if ($null -eq $raw) { return }
        try { $msg = $raw | ConvertFrom-Json } catch { continue }
        $p = $msg.params
        if ($msg.method -eq 'Browser.downloadWillBegin') {
            $script:downloads[[string]$p.guid] = @{ frameId = [string]$p.frameId; name = [string]$p.suggestedFilename; state = 'inProgress'; owner = $null }
        } elseif ($msg.method -eq 'Browser.downloadProgress' -and $script:downloads.ContainsKey([string]$p.guid)) {
            $script:downloads[[string]$p.guid].state = [string]$p.state
        }
    }
}

# All frame ids of a window (a download can start from an iframe)
function Get-FrameIds($ws) {
    $ids = @()
    try {
        $t = Invoke-Cdp $ws 'Page.getFrameTree' @{} 10
        $stack = New-Object System.Collections.Stack
        $stack.Push($t.frameTree)
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            $ids += [string]$n.frame.id
            foreach ($c in @($n.childFrames)) { if ($c) { $stack.Push($c) } }
        }
    } catch { }
    return $ids
}

# Rename the finished <guid> file to its real name (adds " (1)" etc. if the name exists)
function Save-Download([string]$guid, [string]$name) {
    for ($try = 0; $try -lt 10; $try++) {
        $src = Get-ChildItem -LiteralPath $OutDir -File | Where-Object { $_.Name -like "$guid*" } | Select-Object -First 1
        if ($src) {
            $name = $name -replace '[\\/:*?"<>|]', '_'
            if (-not $name) { $name = $guid }
            $base = [IO.Path]::GetFileNameWithoutExtension($name); $ext = [IO.Path]::GetExtension($name)
            $dest = Join-Path $OutDir $name; $k = 1
            while (Test-Path -LiteralPath $dest) { $dest = Join-Path $OutDir "$base ($k)$ext"; $k++ }
            try { Move-Item -LiteralPath $src.FullName -Destination $dest -ErrorAction Stop; return $dest } catch { }
        }
        Start-Sleep -Milliseconds 500          # Chrome may still be closing the file
    }
    return $null
}

function Save-Debug($ws, [string]$num) {
    Save-Screenshot $ws (Join-Path $DebugDir "$num.png")
    try {
        $json = Invoke-Js $ws ($NotePageJs.Replace('__MODE__', 'dump').Replace('__NUM__', $num))
        if ($json -and $json -ne 'login') {
            [IO.File]::WriteAllText((Join-Path $DebugDir "${num}_buttons.txt"), $json, [Text.Encoding]::UTF8)
        }
    } catch { }
}

function Invoke-RealClick([double]$x, [double]$y, $ws = $page, [switch]$Front) {
    # Send real mouse events via CDP (SAPUI5 buttons ignore JS .click())
    if ($Front) { try { Invoke-Cdp $ws 'Page.bringToFront' @{} 10 | Out-Null; Start-Sleep -Milliseconds 300 } catch { } }
    Invoke-Cdp $ws 'Input.dispatchMouseEvent' @{ type = 'mouseMoved'; x = $x; y = $y } 10 | Out-Null
    Start-Sleep -Milliseconds 100
    Invoke-Cdp $ws 'Input.dispatchMouseEvent' @{ type = 'mousePressed'; x = $x; y = $y; button = 'left'; clickCount = 1 } 10 | Out-Null
    Start-Sleep -Milliseconds 80
    Invoke-Cdp $ws 'Input.dispatchMouseEvent' @{ type = 'mouseReleased'; x = $x; y = $y; button = 'left'; clickCount = 1 } 10 | Out-Null
}

function Invoke-NoteJs($ws, [string]$mode, [string]$num) {
    try { return Invoke-Js $ws ($NotePageJs.Replace('__MODE__', $mode).Replace('__NUM__', $num)) }
    catch { return 'wait' }
}

# 'T|x|y|kind|desc' -> real mouse click; returns kind and desc
function Invoke-Target($ws, [string]$r, [switch]$Front) {
    $parts = $r.Split('|', 5)
    Start-Sleep -Milliseconds 300          # let scrollIntoView finish
    Invoke-RealClick ([double]$parts[1]) ([double]$parts[2]) $ws -Front:$Front
    return $parts[3], $parts[4]
}

# ------------------------------------------------------------------
# One browser window = one worker. Each worker is stepped about once a second:
#   idle -> find (load page, click Download, max 60 s) -> wait (download, max 90 s to start) -> idle
# ------------------------------------------------------------------
function Write-Tab($t, [string]$text) {
    $w = if ($script:tabCount -gt 1) { " [win $($t.id)]" } else { '' }
    Write-Host "[$($t.idx)/$($list.Count)] Note $($t.num)${w}: $text"
}

function Complete-Tab($t, [string]$status, [string]$msg) {
    Write-Tab $t "$status - $msg"
    $script:results += [pscustomobject]@{ note = $t.num; status = $status; message = $msg }
    $t.phase = 'idle'; $t.nextAt = (Get-Date).AddSeconds($Delay)
}

function Start-TabNote($t) {
    $t.phase = 'find'; $t.start = Get-Date; $t.state = 'wait'; $t.lastXY = ''
    $t.renav = $false; $t.moreCount = 0; $t.moreAt = $null; $t.guid = $null
    $t.loginGen = $script:loginGen          # to know if another window logged in again meanwhile
    try { Invoke-Cdp $t.ws 'Page.navigate' @{ url = ($NoteUrl -f $t.num) } 30 | Out-Null } catch { }
}

function Step-Tab($t) {
    $now = Get-Date
    switch ($t.phase) {
        'idle' {
            if ($now -lt $t.nextAt) { return }
            if ($script:next -ge $list.Count) { $t.phase = 'done'; return }
            $t.num = $list[$script:next]; $script:next++; $t.idx = $script:next
            $t.loginRetried = $false
            Start-TabNote $t
        }
        'find' {
            # Wait for the page to load and find the Download button (max 60 s)
            # First 20 s: only click when nothing is loading; then relax and try the More menu
            # Button must be found at the same position twice in a row (page is stable)
            $elapsed = ($now - $t.start).TotalSeconds
            if ($elapsed -ge 60) {
                if ($t.state -eq 'wrong-page') { Complete-Tab $t 'ERROR' 'Cannot open the page for this note'; return }
                Save-Debug $t.ws $t.num
                $why = if ($t.state -in 'busy', 'covered') { 'Page kept loading / button was covered' } else { 'Download button not found' }
                Complete-Tab $t 'NO_DOWNLOAD' "$why (diagnostics: _debug\$($t.num)_buttons.txt)"
                return
            }
            $mode = if ($elapsed -gt 20) { 'find-loose' } elseif ($elapsed -gt 5) { 'find-more' } else { 'find' }
            $r = Invoke-NoteJs $t.ws $mode $t.num
            if ($r -eq 'login') { $t.phase = 'login'; return }
            if ($r -like 'T|*') {
                $parts = $r.Split('|', 5)
                if ($parts[3] -eq 'more') {
                    # Download button is hidden in the "..." menu (narrow window): open it (max 3 times, 5 s apart)
                    if ($t.moreCount -lt 3 -and (-not $t.moreAt -or ($now - $t.moreAt).TotalSeconds -ge 5)) {
                        $t.moreCount++; $t.moreAt = $now
                        Invoke-Target $t.ws $r | Out-Null
                    }
                    $t.state = 'wait'; return
                }
                $xy = $parts[1] + '|' + $parts[2]
                if ($xy -ne $t.lastXY) { $t.lastXY = $xy; $t.state = 'found'; return }   # confirm again next second
                Invoke-Target $t.ws $r | Out-Null
                Write-Tab $t "clicked: $($parts[4]) - waiting for download..."
                $t.phase = 'wait'; $t.start = Get-Date; $t.clickedAt = $t.start
                $t.dialogChecks = 0; $t.reclicks = 0
                return
            }
            $t.state = $r; $t.lastXY = ''
            if ($r -eq 'wrong-page' -and $elapsed -gt 10 -and -not $t.renav) {   # page did not navigate -> try once more
                $t.renav = $true
                try { Invoke-Cdp $t.ws 'Page.navigate' @{ url = ($NoteUrl -f $t.num) } 30 | Out-Null } catch { }
            }
        }
        'wait' {
            $elapsed = ($now - $t.start).TotalSeconds
            if ($t.guid) {                       # download started: wait for it to finish (max 10 min)
                $d = $script:downloads[$t.guid]
                if ($d.state -eq 'completed') {
                    $path = Save-Download $t.guid $d.name
                    if ($path) { Complete-Tab $t 'OK' $path }
                    else { Complete-Tab $t 'ERROR' "Download finished but file $($t.guid) not found in $OutDir" }
                } elseif ($d.state -eq 'canceled') {
                    Complete-Tab $t 'ERROR' 'Download was cancelled'
                } elseif ($elapsed -gt 600) {
                    Complete-Tab $t 'ERROR' 'Download did not finish within 10 minutes'
                }
                return
            }
            # No download yet: click a confirmation dialog if any; after 8 s click again (max 2 times,
            # bringing the window to the front). Stops as soon as Chrome reports the download started.
            if ($elapsed -gt 90) {
                Save-Debug $t.ws $t.num
                Complete-Tab $t 'ERROR' "Clicked Download but no file arrived (diagnostics: _debug\$($t.num)_buttons.txt)"
                return
            }
            if ($t.dialogChecks -lt 3 -and $elapsed -gt (3 + 4 * $t.dialogChecks)) {
                $t.dialogChecks++
                $r = Invoke-NoteJs $t.ws 'dialog' $t.num
                if ($r -like 'T|*') {
                    $kind, $d = Invoke-Target $t.ws $r
                    Write-Tab $t "dialog: $d"
                    $t.dialogChecks = 3
                }
                return
            }
            if ($t.reclicks -lt 2 -and $elapsed -gt (8 + 8 * $t.reclicks)) {
                $t.reclicks++
                $r = Invoke-NoteJs $t.ws 'find-loose' $t.num
                if ($r -like 'T|*' -and $r.Split('|', 5)[3] -eq 'more') {      # button is in the "..." menu
                    Invoke-Target $t.ws $r -Front | Out-Null
                    Start-Sleep -Milliseconds 1000
                    $r = Invoke-NoteJs $t.ws 'find-loose' $t.num
                }
                if ($r -like 'T|*' -and $r.Split('|', 5)[3] -eq 'download') {
                    Invoke-Target $t.ws $r -Front | Out-Null
                    Write-Tab $t 'clicked again'
                }
            }
        }
    }
}

# Give each new download to the window that started it
function Set-DownloadOwners {
    $free = @($script:downloads.Keys | Where-Object { -not $script:downloads[$_].owner })
    if ($free.Count -eq 0) { return }
    $waiting = @($script:tabs | Where-Object { $_.phase -eq 'wait' -and -not $_.guid } | Sort-Object { $_.clickedAt })
    foreach ($g in $free) {
        $d = $script:downloads[$g]
        $t = $waiting | Where-Object { -not $_.guid -and ((Get-FrameIds $_.ws) -contains $d.frameId) } | Select-Object -First 1
        if (-not $t) {
            # e.g. started from a pop-up: give it to the window that has waited longest
            $t = $waiting | Where-Object { -not $_.guid } | Select-Object -First 1
        }
        if ($t) {
            $d.owner = $t.id; $t.guid = $g
            Write-Tab $t "download started: $($d.name)"
        }
    }
}

# ------------------------------------------------------------------
# Disable the password manager in the automation Chrome profile (so the "Save password?" bubble does not cover buttons)
# Only changes .sap_profile, not your normal Chrome profile
# ------------------------------------------------------------------
function Disable-PasswordBubble {
    try {
        $dir = Join-Path $ProfileDir 'Default'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $pref = Join-Path $dir 'Preferences'
        $keys = 'password_manager_enabled', 'password_manager_leak_detection'
        $json = if (Test-Path -LiteralPath $pref) { [IO.File]::ReadAllText($pref) } else { '' }
        if ($json.Trim() -match '^\{\s*\}$' -or -not $json.Trim()) {
            $json = '{"credentials_enable_service":false,"profile":{"password_manager_enabled":false,"password_manager_leak_detection":false}}'
        } else {
            # top level: credentials_enable_service
            if ($json -match '"credentials_enable_service"\s*:\s*(true|false)') {
                $json = $json -replace '"credentials_enable_service"\s*:\s*(true|false)', '"credentials_enable_service":false'
            } else {
                $json = ([regex]'^\s*\{').Replace($json, '{"credentials_enable_service":false,', 1)
            }
            # profile.password_manager_enabled / password_manager_leak_detection
            foreach ($k in $keys) {
                if ($json -match ('"' + $k + '"\s*:\s*(true|false)')) {
                    $json = $json -replace ('"' + $k + '"\s*:\s*(true|false)'), ('"' + $k + '":false')
                } elseif ($json -match '"profile"\s*:\s*\{\s*\}') {
                    $json = ([regex]'"profile"\s*:\s*\{\s*\}').Replace($json, ('"profile":{"' + $k + '":false}'), 1)
                } elseif ($json -match '"profile"\s*:\s*\{') {
                    $json = ([regex]'"profile"\s*:\s*\{').Replace($json, ('"profile":{"' + $k + '":false,'), 1)
                } else {
                    $json = ([regex]'^\s*\{').Replace($json, ('{"profile":{"' + $k + '":false},'), 1)
                }
            }
        }
        [IO.File]::WriteAllText($pref, $json, (New-Object Text.UTF8Encoding($false)))
    } catch {
        Write-Host "(Could not disable the Chrome save-password prompt: $($_.Exception.Message))"
    }
}

# ------------------------------------------------------------------
# Start the browser (separate profile + remote debugging)
# ------------------------------------------------------------------
$browserArgs = @(
    "--remote-debugging-port=$Port",
    '--remote-allow-origins=*',
    "--user-data-dir=`"$ProfileDir`"",
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-features=PasswordLeakDetection,PasswordManagerOnboarding',
    # keep windows that are behind other windows fully running (page loading, clicks)
    '--disable-backgrounding-occluded-windows',
    '--disable-renderer-backgrounding',
    '--disable-background-timer-throttling',
    'about:blank'
)
Disable-PasswordBubble
Start-Process -FilePath $browserExe -ArgumentList $browserArgs | Out-Null

$version = $null
for ($i = 0; $i -lt 30 -and -not $version; $i++) {
    Start-Sleep -Seconds 1
    try { $version = Get-LocalJson "http://127.0.0.1:$Port/json/version" } catch { }
}
if (-not $version) { throw 'Cannot connect to the browser (remote debugging may be blocked by company policy)' }

$browserWs = Connect-Cdp $version.webSocketDebuggerUrl
# Save downloads straight into OutDir (named by guid, renamed when finished), no Save As dialog
Invoke-Cdp $browserWs 'Browser.setDownloadBehavior' @{ behavior = 'allowAndName'; downloadPath = $OutDir; eventsEnabled = $true } | Out-Null

$pageTarget = Get-LocalJson "http://127.0.0.1:$Port/json" |
              Where-Object { $_.type -eq 'page' } | Select-Object -First 1
$page = Connect-Cdp $pageTarget.webSocketDebuggerUrl

# Maximize a window: on a wide page SAP shows "Download for SNOTE" directly instead of in the "..." menu
function Set-WindowMaximized([string]$targetId) {
    try {
        $w = Invoke-Cdp $browserWs 'Browser.getWindowForTarget' @{ targetId = $targetId } 10
        Invoke-Cdp $browserWs 'Browser.setWindowBounds' @{ windowId = $w.windowId; bounds = @{ windowState = 'maximized' } } 10 | Out-Null
    } catch { }
}
Set-WindowMaximized $pageTarget.id

$script:results = @()
try {
    if (-not (Invoke-AutoLogin $page $HomeUrl)) { throw 'Cannot log in to SAP for Me, stopping.' }
    $script:loginGen = 0                    # +1 every time we log in again after the session expired

    # --------------------------------------------------------------
    # Open the extra windows (logged in already: they share the cookies)
    # --------------------------------------------------------------
    $script:tabCount = [Math]::Max(1, [Math]::Min($Windows, $list.Count))
    $script:tabs = @(@{ id = 1; ws = $page; phase = 'idle'; nextAt = Get-Date })
    for ($i = 2; $i -le $script:tabCount; $i++) {
        try {
            $tg = Invoke-Cdp $browserWs 'Target.createTarget' @{ url = 'about:blank'; newWindow = $true }
            Set-WindowMaximized $tg.targetId
            $ws = Connect-Cdp "ws://127.0.0.1:$Port/devtools/page/$($tg.targetId)"
            $script:tabs += @{ id = $i; ws = $ws; phase = 'idle'; nextAt = Get-Date }
        } catch {
            Write-Host "(Could not open window ${i}: $($_.Exception.Message))"
        }
    }
    $script:tabCount = $script:tabs.Count
    Write-Host "Downloading $($list.Count) note(s) with $($script:tabCount) window(s)..."

    # --------------------------------------------------------------
    # Run all windows until every note is done
    # --------------------------------------------------------------
    $script:next = 0
    while (@($script:tabs | Where-Object { $_.phase -ne 'done' }).Count -gt 0) {
        foreach ($t in $script:tabs) {
            if ($t.phase -eq 'done') { continue }
            if ($t.lastTick -and ((Get-Date) - $t.lastTick).TotalMilliseconds -lt 1000) { continue }
            $t.lastTick = Get-Date
            try {
                Step-Tab $t
                if ($t.phase -eq 'login') {
                    # session expired -> log in again (once per note), then reload the note
                    if ($t.loginRetried) { Complete-Tab $t 'ERROR' 'Login required again'; continue }
                    $t.loginRetried = $true
                    # another window already logged in again since this note started -> just reload
                    if ($t.loginGen -eq $script:loginGen) {
                        Write-Tab $t 'session expired, logging in again...'
                        if (-not (Invoke-AutoLogin $t.ws $null)) { Complete-Tab $t 'ERROR' 'Login required again'; continue }
                        $script:loginGen++
                    }
                    Start-TabNote $t
                }
            } catch {
                if ($t.num -and $t.phase -in 'find', 'wait', 'login') { Complete-Tab $t 'ERROR' $_.Exception.Message }
            }
            Update-DownloadState
            Set-DownloadOwners
        }
        Start-Sleep -Milliseconds 200
    }
} finally {
    try { Invoke-Cdp $browserWs 'Browser.close' | Out-Null } catch { }
}
$results = @($script:results | Sort-Object { $list.IndexOf($_.note) })

# ------------------------------------------------------------------
# Finish
# ------------------------------------------------------------------
$log = Join-Path $OutDir 'download_log.csv'
try {
    $results | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
} catch {
    # e.g. old log is open in Excel -> use another name
    $log = Join-Path $OutDir ("download_log_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))
    $results | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
}

$ok = @($results | Where-Object status -eq 'OK').Count
Write-Host ''
Write-Host "Done: $ok/$($results.Count) succeeded. Files are in $OutDir"
Write-Host "Log: $log"
if ($ok -lt $results.Count) { Write-Host "Screenshots of failed notes are in $DebugDir" }
