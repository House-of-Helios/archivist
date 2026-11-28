# Archivist

Back up any drive, or any folders, to any other drive. Archivist copies each kind of drive the way it moves best, keeps every Mac file detail, never leaves a half-copied file (each file is written whole under a temporary name, then renamed, and a file that changed while it was read is copied again), and keeps what you change or delete in a dated `_📚archive` folder beside the backup. It compares by size and modification date; a read-back checksum pass is on the list.

Free and open source (GPL-3.0), by House of Helios. macOS 14 Sonoma or later, Apple silicon and Intel.

## Install

1. Open **[Releases](https://github.com/House-of-Helios/archivist/releases/latest)** and download **`Archivist.dmg`**.
   (The green "Code → Download ZIP" button gives you the source code, not the app.)
2. Open the DMG and drag **Archivist** onto **Applications**.
3. Open Archivist from Applications.

### "Archivist can't be opened"
House of Helios doesn't pay Apple for a developer account, so macOS doesn't know the maker. The first time only:

1. Open Archivist. macOS says it can't check it; click **Done**.
2. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Archivist.
3. Confirm with **Open**. From then on it opens like any other app.

## Using it

- **Sources:** drop folders or a whole drive on the left, or press **+**.
- **Destination:** drop the folder where the backup should live on the right.
- **Start backup.** The bar along the bottom shows each source and the time left.
- **⚙️ Settings:** name and picture, a schedule (hourly, daily, weekly, or whenever the destination is connected), and how long to keep earlier versions.

Backing up a whole drive or your home folder needs **Full Disk Access**: System Settings → Privacy & Security → Full Disk Access → turn on Archivist.

## Folders on another Mac

Archivist can back up from, or to, a folder shared by another Mac. Connect to it in Finder first (**Go → Connect to Server**), then drop it in like any other folder.

**On the Mac that shares the folder:**
1. **System Settings → General → Sharing → File Sharing:** on, with the folder in the list.
2. **System Settings → Network → Firewall:** if it is on, open **Options…**, turn off **Block all incoming connections** and **Enable stealth mode**, and set **File Sharing** to **Allow incoming connections**.

**On the Mac running Archivist:** the first time it reads a shared folder, macOS asks whether Archivist may use files on a network volume. Click **Allow**. If the question was missed, the window says **Waiting for your OK**; the answer lives in **System Settings → Privacy & Security → Files & Folders → Archivist → Network Volumes**.

Pulling (Archivist runs on the Mac that keeps the backup and reads the other Mac's folder) is much faster than pushing for folders with many small files: in our test, 19 s against about 2½ minutes for 5,200 files over Wi-Fi. Big files go at the network's speed either way.

## Updates

Archivist checks this repository's releases. When a newer version is out, a green **Update** button appears at the top; it downloads, checks the release's signature and fingerprint, and restarts into the new version.

## Build from source

```
brew install xcodegen
xcodegen generate
xcodebuild -project Archivist.xcodeproj -scheme Archivist -configuration Release build
```

The copy engine is a Swift package in `ArchivistCore/` (`swift test` there runs its tests).
