# SAP Note Downloader

Batch-download SAP Note files ("Download for SNOTE") from SAP for Me (me.sap.com) with your own S-user.

Nothing to install: it uses the built-in Windows PowerShell and Google Chrome (or Microsoft Edge if Chrome is not installed).

## Usage

1. Double-click `Run_SAP_Note_Download.bat`.
2. First run only: enter your S-user (or email) and password. They are encrypted with Windows DPAPI in `.sap_credential.xml`, so only your Windows account on this PC can read them.
3. Pick a txt file with note numbers (one per line, `#` starts a comment, see `notes.txt.example`). Press Cancel to type the numbers instead.
4. The files are saved in `sap_notes\`, with a summary in `sap_notes\download_log.csv`.

If SAP asks for MFA, complete it in the browser window and press Enter in the console.

## Features

- Automatic login, including the "Account selection" page when one email has several S-users. You choose the account once; the choice is saved in `.sap_account.txt`.
- Downloads several notes at the same time in separate browser windows (default 3). To change it:

  ```bat
  Run_SAP_Note_Download.bat -Windows 1
  ```

  Allowed values: 1 to 6.
- Waits until the page has finished loading before clicking, and opens the "..." menu when SAP hides the Download button there.
- Logs in again automatically if the session expires during a run.
- When a note fails, a screenshot and a list of the page's buttons are saved in `sap_notes\_debug\`.

## Options

Pass these to `Run_SAP_Note_Download.bat`:

| Option | Default | Meaning |
|---|---|---|
| `-Notes 3503016,3262931` | | Note numbers to download (no file dialog) |
| `-NotesFile path\to\notes.txt` | | Txt file with note numbers (no file dialog) |
| `-OutDir path` | `sap_notes` | Download folder |
| `-Windows n` | `3` | Browser windows downloading at the same time (1 to 6) |
| `-Delay seconds` | `3` | Pause between notes in each window |

## Change password or account

Double-click `Reset_Login.bat`. It deletes the saved password and account choice; you enter them again on the next run.

## Files created locally

These contain your login data or downloads and are listed in `.gitignore`. Do not share them:

- `.sap_credential.xml`: encrypted S-user and password
- `.sap_account.txt`: chosen S-user account
- `.sap_profile\`: separate browser profile used by the tool
- `sap_notes\`: downloaded files, log and diagnostics
