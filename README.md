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
3. **Double-click `multilink.bat`**.
4. Press **1** and hit Enter. This checks everything is set up right.
5. Press **2**, paste your download link, hit Enter. Done.

That's it. You don't need to understand anything below.

---

## What's in this folder

| File | What it's for |
|---|---|
| **`multilink.bat`** | **Start here.** Double-click it. Windows. |
| `multilink.ps1` | The engine the .bat runs. Keep it next to the .bat. |
| `multilink.sh` | Same tool for a Linux PC. |
| `fastdl.ps1` | Simpler one-purpose version: just downloads, no menu. |
| `reset-network.ps1` | **Undo everything.** Safe by default — run it plain and it only reports. |
| `multi-link-downloads.md` | The deep technical guide. Read if you're curious *why* this works. |
| `README.md` | This file. |

Keep `multilink.bat` and `multilink.ps1` **together in the same folder** or the
launcher won't find the engine.

---

## The menu explained

```
1) Check my connections      <- run this first, and any time something seems off
2) Download using ALL connections    <- the fast one
3) Download using ONE connection     <- use this while gaming (see below)
4) Prefer my low-latency link        <- fixes lag. Asks for admin.
5) Undo that
6) Quit
```

### Option 1 tells you the two things that matter

**Are my two connections actually separate?** It shows a "public IP" for each one.

- Two **different** IPs = good, you'll get the speed boost.
- Two **identical** IPs = your phone is on Wi-Fi. Turn its Wi-Fi off and re-run.

**Is something already eating my internet?** If Steam or Windows Update is
downloading, it will say so. Speed tests taken while that's happening are
meaningless — pause the other download first.

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

- **Run menu option 4 once** and pick your **wired** connection. That sends games
  and browsing down the good cable instead of the 5G. Big difference.
- **Downloading while gaming?** Use menu option **3** and pick the **5G tether**.
  The download uses your phone, your game keeps the clean cable. No lag spikes.
- In Steam: **Settings → Downloads → Limit bandwidth**, and untick
  *"Allow downloads during gameplay"*. Steam will happily use 600+ Mbps and ruin
  your ping if you let it.

---

## ⚠️ Mobile data warning — please read

When both links are running, downloads pull data through your phone **very** fast.

At the speeds this PC hit, that's roughly **4 GB of mobile data per minute.**

In one session here, **24.5 GB** went through the phone. If you're not on a truly
unlimited 5G plan, that is real money.

**Before a big download:** decide whether you want the phone involved at all. If
not, either unplug it or use menu option **3** and pick the wired connection.
Also worth turning on: *Settings → Network & Internet → (your tether) →
Metered connection*.

---

## What this will NOT do

Being straight with you so there are no surprises:

- ❌ **It won't speed up browsing, YouTube, or Netflix.** Those use one connection
  at a time. Only file downloads through this tool get the boost.
- ❌ **It won't speed up every download.** The website has to support "range
  requests". Most big download sites and game CDNs do; some don't.
- ❌ **It won't reduce your ping.** See the gaming section.
- ❌ **It won't survive your phone reconnecting to Wi-Fi.** That happens
  automatically when you get home. Re-run option 1 to check.
- ❌ **Nothing is permanently "joined".** There's no bonded connection created.
  Each download decides to use both links, or not.

Steam, by the way, **already** does this on its own — it opens dozens of
connections and spreads them over both links without any setup. This tool gives
that same ability to normal downloads.

---

## Linux

```bash
chmod +x multilink.sh
./multilink.sh
```

Same menu. One extra step Linux needs that Windows doesn't: run
`sudo ./multilink.sh setup` if the check shows both paths with the same public IP.
Linux ignores source binding until you add routing rules; the script does it for you.

---

## If something goes wrong

| What you see | What to do |
|---|---|
| Both paths show the same public IP | Turn the phone's Wi-Fi OFF |
| "Only 1 usable path" | Phone isn't tethering — check the USB cable and that tethering is on |
| Speeds look terrible | Something else is downloading. Pause Steam and re-check |
| "running scripts is disabled" | Use `multilink.bat`, don't run the .ps1 directly |
| Download won't split | That server doesn't support range requests — nothing to fix |
| Game is laggy | Run option 4, pick wired |

---

## Undoing it all

Nothing here changes your network until you run menu option 4. If you want to put
everything back:

```powershell
# 1. See what would change. Changes NOTHING. Run this first.
powershell -ExecutionPolicy Bypass -File "reset-network.ps1"

# 2. Actually revert (run from an ADMIN PowerShell)
powershell -ExecutionPolicy Bypass -File "reset-network.ps1" -Apply

# 3. Also uninstall aria2 and delete the loose scripts in your home folder
powershell -ExecutionPolicy Bypass -File "reset-network.ps1" -Apply -RemoveTools
```

It restores automatic interface metrics, removes any NIC team, and clears temp
files. It deliberately does **not** touch your Hyper-V adapters, your adapter
bindings, or your own static routes — it lists routes and lets you decide, because
guessing which ones are yours would be reckless.

Three things no script can undo for you: the **Metered connection** toggle
(Settings → Network & Internet → adapter), your **phone's** Wi-Fi and tethering
switches, and apps that are already holding connections on one link — restart
those so they move over.

On Linux the equivalent is `sudo ./multilink.sh undo`.

---

## Want the full story?

`multi-link-downloads.md` has the whole thing: why Windows NIC teaming can't do
this, why a single connection can never be split without a paid service, the exact
commands, and the mistakes made while working this out (including one where the
wired connection was wrongly declared broken because a Steam download was hogging it).
