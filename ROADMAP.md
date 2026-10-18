# Roadmap

What's planned or under consideration after **v2.0.0** (the Multilink console).
Nothing here is built yet.

---

## Next up

### 1. Chrome downloads go through Multilink automatically

**Why:** today only downloads started from the console use both links. A
download started in Chrome rides the single route Windows picks (Ethernet), so
it's capped at the wired speed while the phone sits idle. Copying the link from
Chrome into the console works but is tedious.

**How it would work:** a small Chrome extension (Manifest V3), the same approach
download managers like IDM use.

1. You start a download in Chrome as usual.
2. The extension sees it start (`chrome.downloads.onCreated`), pauses it, and asks
   the console: is it running, and will this server split?
3. If yes, it cancels the Chrome copy and the console downloads it over all links.
4. If not (console not running, server won't split, small file), Chrome keeps the
   download as normal. Nothing breaks.

**Details to build:**

- **Setup:** load once from `chrome://extensions` → Developer mode → Load unpacked.
  Chrome does not allow silent installs.
- **Logged-in downloads** (Google Drive, sites behind a login): pass that site's
  cookies, referrer and user agent along so aria2 can fetch the file.
- **Security:** the console accepts requests only from its own page today.
  It must accept exactly this extension, identified by its ID, and nothing else.
  The token flow needs a design that doesn't expose it to web pages.
- **Where files land:** your Downloads folder, same as Chrome, but they show in
  the console instead of Chrome's download bar.
- **Also:** a right-click **"Download with Multilink"** on links.

**Open question:** which downloads get captured?

- Big files only, over a size you set (suggested default 50 MB), on servers
  that support splitting.
- Every download the server allows splitting for.
- Only when you ask (right-click only, no automatic capture).

### 2. "No internet on this link" badge

**Why:** when the phone is tethered but not passing traffic, the console shows
the 5G card with public IP "—" and an amber pill. That looks the same as a
working link that's just idle. A red badge on the card and an "offline" marker in
the graph legend would make it obvious.

---

## Later

- **Live ping graph per link.** A small latency/jitter line under each link card,
  so lag spikes show as they happen.
- **Download queue and history.** Several links in a queue, plus a finished list
  with size, time, average speed and GB over 5G. Kept across restarts.
- **Single-instance console.** A second console window currently stops the first
  one's per-app monitor. Opening Multilink again should focus the existing console.

---

## Known minor issues (from the v2.0.0 code review)

- `/api/downloads` can occasionally return an error while a download is running
  (its per-link counters are read while being updated). The page retries silently.
- The wired baseline job and saving settings can write the settings file at the
  same moment.
- The data cap is read using the Windows locale (on German Windows "7.5" becomes 75).
- `reset-network.ps1`'s leftover-monitor check only understands English Windows.
- Process names are cached forever: a reused process ID can show the wrong app name.
- The launcher falls back to non-admin if the folder path contains an apostrophe.
- Starting a download, Fix game lag and Undo briefly hold up other requests.
- Shutdown cleanup can run past Windows' 5-second close window (aria2 is still
  stopped by the Job Object).
- The mobile-link label in the data tile is HTML-escaped twice.
- **Local programs:** any program already running on this PC can read the page's
  token and drive the console, including when it runs as admin. Restricting the
  download folder would narrow this.

---

## Not planned

- **Moving an app to a different link** ("force Steam onto 5G"). Windows can't do
  it without installing a network driver, which would break the "nothing
  permanent, easy to undo" design.
- **A web console on Linux.** The per-app monitor uses Windows-only APIs; Linux
  keeps `multilink.sh`.
