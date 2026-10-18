# Internet Speed — use both your connections at once

This folder makes **one big download** arrive faster by using your **wired internet
and your phone's 5G at the same time**.

Measured on this PC: **151 Mbps** on wired alone → **403 Mbps** using both. About **2.7× faster**.

---

## Just want it to work? (Windows)

1. Plug your phone into the PC with a USB cable.
2. On the phone: turn **Wi-Fi OFF**, turn **mobile data ON**, turn **USB tethering ON**.
   - ⚠️ The Wi-Fi bit is the part everyone gets wrong. If the phone stays on Wi-Fi,
     its internet comes from your home router and you gain **nothing**.
3. **Double-click `multilink.bat`** and say **Yes** to the Windows prompt.
4. The **Multilink console** opens in your browser. Paste a download link, press
   **Start download**. Done.

The first time, it asks whether to put a **Multilink** shortcut on your desktop,
and installs `aria2` (the download engine) if it's missing.

---

## What's in this folder

| File | What it's for |
|---|---|
| **`multilink.bat`** | **Start here.** Double-click it. Opens the console. |
| `multilink.ps1` | The engine the console runs on. Keep it next to the .bat. |
| `console/` | The console itself: the local web server and the page. Keep it next to the .bat. |
| `reset-network.ps1` | **Undo everything.** Safe by default — run it plain and it only reports. Also a button in the console. |
| `multilink.sh` | Same idea for a Linux PC (terminal menu). |
| `multilink.desktop` | Linux launcher for `multilink.sh`. |
| `multi-link-downloads.md` | The deep technical guide. Read if you're curious *why* this works. |
| `ROADMAP.md` | What's planned next, including Chrome downloads going through Multilink automatically. |
| `tests/` | Automated tests for the console. |

Keep `multilink.bat`, `multilink.ps1` and the `console` folder **together** or the
launcher won't start.

---

## The console

| Part | What it shows or does |
|---|---|
| **Top bar** | Whether your two links are really separate (green), the link address `localhost:8642 · local only`, and whether you're running as admin. |
| **Combined throughput** | Total speed right now, and how much each link is carrying. |
| **Speed-up** | Total ÷ your wired-only speed. Press **Measure wired (10 s)** once so it has a real number to compare with. |
| **Mobile data this session** | GB through the phone since the console started, and the **cap** (see below). |
| **Live throughput** | Graph of the last 60 seconds: wired at the bottom, 5G stacked on top. Hover for exact numbers. |
| **Link cards** | Local IP, public IP, metric, ping, jitter and loss for each connection. The lowest-latency one is marked **Gaming link**. |
| **Apps using the network** | Which programs are using the internet, how fast, and **on which link**. A game partly on 5G is flagged **laggy link**. |
| **Run check** | Finds your links, confirms they're separate, checks for background traffic, measures ping. Run it whenever something seems off. |
| **Download a file** | **All links** = the fast one. **One link** = keep the other free (e.g. download over 5G while gaming on the cable). The line under the link tells you whether the server will split across links. |
| **Fix game lag** | Sends games and browsing down your lowest-latency link. **Undo** puts it back. |
| **Reset network** | Shows what would be put back to Windows defaults; **Apply reset** does it. |

**Admin or not?** Say **Yes** to the Windows prompt and everything works. Say **No**
and the console still opens, but per-app speeds show only which apps are connected
(no speeds), and **Fix game lag** / **Reset** ask you to restart as administrator.

**Two automatic guards:**

- **Speed boost lost** — every minute the console checks each link's public IP.
  If the phone silently joins Wi-Fi (it does when you get home), a red banner
  tells you, instead of you wondering why downloads got slow.
- **Mobile data cap** — set "Switch to wired-only at N GB". When the phone has
  carried that much this session, the download continues on the cable only, and
  nothing already downloaded is lost. A download you deliberately put on **5G only**
  is paused instead (so your game on the cable isn't disturbed); raise the cap and
  press **Resume** to continue.

To stop the console, press **Stop console** or close its PowerShell window.

---

## Gaming: read this bit

Using both connections does **not** reduce lag. Games don't need speed, they need
a *stable* connection, and your 5G is much worse at that than your cable.

Your two links, measured:

| | Ping | Jitter (wobble) |
|---|---|---|
| Wired | **11.5 ms** ✅ | 1.3 ms ✅ |
| 5G tether | 523 ms ❌ | 90.8 ms ❌ |

So:

- **Press Fix game lag once** with your **wired** link selected. That sends games
  and browsing down the good cable instead of the 5G. Big difference.
- **Downloading while gaming?** Choose **One link** and pick the **5G tether**.
  The download uses your phone, your game keeps the clean cable. No lag spikes.
- Watch **Apps using the network**: if your game shows **laggy link**, it's partly
  on 5G — press Fix game lag and restart the game.
- In Steam: **Settings → Downloads → Limit bandwidth**, and untick
  *"Allow downloads during gameplay"*. Steam will happily use 600+ Mbps and ruin
  your ping if you let it.

---

## ⚠️ Mobile data warning — please read

When both links are running, downloads pull data through your phone **very** fast.

At the speeds this PC hit, that's roughly **4 GB of mobile data per minute.**

In one session here, **24.5 GB** went through the phone. If you're not on a truly
unlimited 5G plan, that is real money.

**Before a big download:** set the **cap** in the console (default 10 GB), or choose
**One link** with the wired connection. Also worth turning on:
*Settings → Network & Internet → (your tether) → Metered connection*.

The cap only governs downloads started from the console — it can't stop other apps
from using the phone link.

---

## What this will NOT do

Being straight with you so there are no surprises:

- ❌ **It won't speed up browsing, YouTube, or Netflix.** Those use one connection
  at a time. Only file downloads through the console get the boost.
- ❌ **It won't speed up every download.** The website has to support "range
  requests". The console tells you before you start.
- ❌ **It won't reduce your ping.** See the gaming section.
- ❌ **It can't move an app to a different link** (e.g. "force Steam onto 5G").
  Windows can't do that without installing a network driver. The console shows
  which link each app uses; it doesn't move them.
- ❌ **Nothing is permanently "joined".** There's no bonded connection created.
  Each download decides to use both links, or not.

Steam, by the way, **already** does this on its own — it opens dozens of
connections and spreads them over both links without any setup. This tool gives
that same ability to normal downloads.

---

## Linux

The console is Windows-only. On Linux use the terminal script:

```bash
chmod +x multilink.sh
./multilink.sh
```

To launch it from your app menu, edit the `Exec=` path in `multilink.desktop` to
point at this folder, then:

```bash
cp multilink.desktop ~/.local/share/applications/
```

One extra step Linux needs that Windows doesn't: run `sudo ./multilink.sh setup`
if the check shows both paths with the same public IP. Linux ignores source
binding until you add routing rules; the script does it for you.

---

## If something goes wrong

| What you see | What to do |
|---|---|
| Red **Speed boost lost** banner | Turn the phone's Wi-Fi OFF, then press **Re-check now** |
| "Only one internet path · plug in your phone" | Phone isn't tethering — check the USB cable and that tethering is on |
| A link shows public IP "—" and the pill is amber | That link has no internet. For the phone: mobile data on, signal OK |
| Speeds look terrible | Something else is downloading. Check **Apps using the network** and pause it |
| "This server does not accept range requests" | That server won't split — nothing to fix, it downloads at normal speed |
| Game is laggy | Press **Fix game lag** with your wired link selected |
| "Restart the console as administrator" | Close the console, double-click `multilink.bat`, say **Yes** to the prompt |
| "The console has stopped" | Double-click `multilink.bat` again |
| Windows says "running scripts is disabled" | Use `multilink.bat`, don't run the .ps1 directly |

---

## Undoing it all

Nothing here changes your network until you press **Fix game lag**. To put
everything back, press **Preview reset** then **Apply reset** in the console, or
run the script directly (it works even if the console won't start):

```powershell
# 1. See what would change. Changes NOTHING. Run this first.
powershell -ExecutionPolicy Bypass -File "reset-network.ps1"

# 2. Actually revert (run from an ADMIN PowerShell)
powershell -ExecutionPolicy Bypass -File "reset-network.ps1" -Apply

# 3. Also uninstall aria2, delete the console's settings and the desktop shortcut
powershell -ExecutionPolicy Bypass -File "reset-network.ps1" -Apply -RemoveTools
```

It restores automatic interface metrics, removes any NIC team, stops a leftover
console monitor session, and clears temp files. It deliberately does **not** touch
your Hyper-V adapters, your adapter bindings, or your own static routes — it lists
routes and lets you decide, because guessing which ones are yours would be reckless.

Three things no script can undo for you: the **Metered connection** toggle
(Settings → Network & Internet → adapter), your **phone's** Wi-Fi and tethering
switches, and apps that are already holding connections on one link — restart
those so they move over.

On Linux the equivalent is `sudo ./multilink.sh undo`.

---

## Want the full story?

`multi-link-downloads.md` has the whole thing: why Windows NIC teaming can't do
this, why a single connection can never be split without a paid service, the exact
commands, how the console is built, and the mistakes made while working this out
(including one where the wired connection was wrongly declared broken because a
Steam download was hogging it).
