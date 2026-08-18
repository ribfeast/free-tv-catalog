# Free TV — live channel catalog

This is the **live channel list** the app reads. Editing `catalog.json` here changes
what people see in the app — **no app update, no App Store resubmission**. The app
re-checks this file on launch and swaps in your changes (allow a few minutes for
the change to propagate).

> The app also ships with a *copy* of this list baked in (a "seed"), so it still
> works on first launch and offline. This hosted file is what lets you change
> channels **after** the app is published.

## How to change channels

1. Open `catalog.json` (on GitHub: click the file, then the ✏️ pencil icon).
2. Add, edit, or remove a channel (see the format below).
3. Save / commit the change ("Commit changes" on GitHub).
4. That's it — the app picks it up within a few minutes.

**Tip:** before saving, paste the whole file into a JSON checker (e.g.
jsonlint.com) to make sure it's still valid — one missing comma breaks the file.
If the file is ever broken or unreachable, the app safely keeps the last good
list, so a mistake won't take the channels down.

## The format

```jsonc
{
  "version": 1,
  "updated": "2026-08-19",           // optional note to yourself; any text
  "channels": [
    {
      "id": "nasa_tv",               // REQUIRED-ish: a short unique tag; keep it
                                     //   stable so favourites stick to the channel
      "name": "NASA TV",             // REQUIRED: what shows on the tile
      "category": "Science",         // optional: groups it under a filter chip
      "streamUrl": "https://…m3u8",  // REQUIRED: the live stream (HLS .m3u8 etc.)
      "logoUrl": "https://…png"      // optional: channel logo (not yet shown, but
                                     //   safe to include for later)
    }
  ]
}
```

Only `name` and `streamUrl` are truly required. A channel missing either is
skipped (it won't break the rest of the list).

### Add a channel
Copy an existing `{ … }` block, change the values, and add a comma between blocks.

### Remove a channel
Delete its `{ … }` block (and tidy up the commas so it's still valid JSON).

## ⚠️ Only add channels we're allowed to redistribute

This is the important rule (it's what keeps the app in the App Store):

- ✅ Channels from their **owner/distributor**, **public-domain**,
  **Creative-Commons**, or **creator** feeds.
- ❌ Do **not** paste channels rebundled from other platforms (Pluto, Samsung TV
  Plus, etc.). "Free to watch there" is **not** "licensed for us to redistribute."

The channels currently in this file are public-domain (NASA), Creative-Commons
(Blender open movies), or official test streams (Apple) — placeholders for
building the app, not launch content.
