# Steam Save Sync

[Português](README.md) | **English**

A Windows app that copies a game's save from one Steam account to one or more other accounts on the same PC, in a few clicks.

Useful if you play the same game on more than one account on the same machine (for example, an offline account and your main account) and want to carry your progress from one to the other.

> The app interface is currently in Brazilian Portuguese.

## What it does

- Lists the **installed** games that have a save in `Steam\userdata` for at least one account.
- Shows the accounts that have a save for each game, with last save date and size.
- Copies the save from a source account to **one or more destination accounts**.
- **Backs up the destination** before overwriting it, on every sync.
- Validates the files before writing and verifies them after the copy.
- Only syncs while Steam is closed (there is a button to close it).

## Supported games

| Game | AppID | Method |
| --- | --- | --- |
| 007 First Light | 3768760 | Full support (save re-signed for the destination account) |
| Any other | - | Plain copy |

**Plain copy** copies the `userdata\<account>\<appid>\remote` folder without changing the files. It works for games that do not bind the save to the account. For games that do (or that keep saves outside `userdata`, such as in `Documents` or `AppData`), the save may not load or the game may not show up in the list at all.

## Installation

Requirements: Windows 10 or 11. Nothing else to install beyond what ships with Windows (PowerShell 5.1 and .NET Framework).

1. Download the repository (**Code > Download ZIP**) and extract it.
2. Double-click `Instalar.cmd`.
3. Open it from the **Steam Save Sync** shortcut on the desktop or in the Start menu.

To run without installing, double-click `SaveSync.cmd`. To remove it, use `Desinstalar.cmd`.

## How to use

1. Close Steam.
2. Pick the game in the sidebar.
3. Pick the **source** account (Origem) and select the **destinations** (Destinos).
4. Click **Sincronizar** and confirm.
5. Open Steam on the destination account. If a Steam Cloud conflict shows up, choose the **local files**.

The destination account must have launched the game at least once, so that its save folder exists.

Backups and preferences are stored in `%LOCALAPPDATA%\SaveSync`.

## Notes

- Use it only with your own accounts.
- The copy may carry stats and achievements along with the progress. For 007 First Light there is an option to leave them out.
- The app only overwrites files; it does not delete slots that exist only on the destination.
- This project is not affiliated with Valve, IO Interactive or any studio. Use at your own risk.

## Adding support for a game

Game profiles live in the `$script:Profiles` table at the top of `SaveSync.ps1`:

```powershell
'3768760' = @{   # 007 First Light
    Method  = 'xor-steamid64'
    Options = @(
        @{ Label = 'Copiar estatísticas e conquistas'; Container = 'LocalProfile' }
    )
}
```

- `Method`: `xor-steamid64` (`index.save`/`data.save` files encrypted with an XOR of the account's SteamID64) or `copy`.
- `Options`: folders inside `remote` that the user can choose to leave out.

For a new format, add a method to `Get-SyncItems`. Run `powershell -ExecutionPolicy Bypass -File SaveSync.ps1 -SelfTest` for a quick test that writes nothing to the saves.

## Credits

The 007 First Light save format was documented by the [007-First-Light-Save-Tools](https://github.com/Dxian998/007-First-Light-Save-Tools) project.

## License

MIT. See `LICENSE`.
