# Free TV — live channel catalogue

`catalog.json` on the **main** branch of this repository is the channel list
every installed copy of the app reads. The app re-fetches it on launch and swaps
in whatever it finds, within a few minutes of a merge. **Merging to main is
therefore a release**: no App Store review, no update, no undo button on the
phones that have already fetched it.

> The app also ships with a copy of this list baked in (the "seed"), so it works
> on first launch and offline. This hosted file is what lets channels change
> **after** the app is published.

Two things guard the file:

- **`validate`** — a check that runs on every pull request and every push
  (`.github/workflows/validate.yml`). It refuses a file the app could read
  wrongly and shouts about changes that move what is on air. Once the merge lock
  below is switched on, GitHub greys out the Merge button until it passes.
- **`streams`** — a weekly sweep of every address in the file
  (`.github/workflows/streams.yml`). When a stream is dead it opens (or updates)
  a GitHub issue titled *"Dead streams found by the weekly sweep"*.

## How to change channels — the real path

**Never edit `catalog.json` by hand, and never use GitHub's pencil icon.** Both
skip the curation record, the assembler's checks and the app repo's tests, and
a hand edit is how a whole catalogue once shipped unreadable. The path is:

1. **Manifest.** In the app repo, `tools/channels/<channel>.json` is the curation
   record: every clip with its page, licence, verbatim credit, true duration
   (from `ffprobe` or the source's own API — never a web page), and every clip
   that was rejected and why. Edit or create that file.
2. **Assembler.** Run `tools/assemble-channel.ps1 -Manifest tools/channels/<channel>.json`
   in the app repo. It emits the catalogue entry and refuses a manifest with a
   missing credit, a non-https address, a duplicate, a zero length or fewer
   than 2 items.
3. **Branch.** In *this* repo, on a new branch (never main): replace the
   channel's entry in `catalog.json` with the emitted one and **raise `version`
   by one**. Run the checker yourself before pushing:

   ```
   dart tools/validate_catalog.dart catalog.json <a copy of main's catalog.json>
   ```

   (Dart comes with Flutter: `C:\Users\james\flutter\bin\dart`.) Read its
   summary — channel and item counts, hours per channel, what changed.
4. **Pull request.** Push the branch and open a pull request. The `validate`
   check runs; its report is on the run's summary page. If the change removes
   a channel or a big share of one channel's items **on purpose**, write the
   words `drop intended` in the pull request description, or the check refuses
   it.
5. **Merge — the owner does this.** Merging is the deploy. Afterwards, fetch the
   live address and confirm it serves the new `version`:
   `https://raw.githubusercontent.com/ribfeast/free-tv-catalog/refs/heads/main/catalog.json`
   (it can lag a few minutes). Until that number is seen, nothing has been
   published — two channels once sat finished on a branch for 13 days.
6. **Seed.** Copy the merged file over the app's bundled seed
   (`app/assets/free_tv_catalog.json`) so a fresh install starts with the same
   channels.

## What the `validate` check refuses

The app's own parser is *forgiving*: it silently skips anything it does not
understand. That is right on a phone (one bad row must not take the channels
down) and wrong at publish time (a silently skipped row is a programme nobody
sees). So `tools/validate_catalog.dart` is deliberately **stricter than the
app**; the app's rules are written out beside each of its checks in the file's
header comment. It fails on:

- an invisible byte-order marker at the start of the file (PowerShell adds one
  when it saves UTF-8 — the app once read such a file as *no channels at all*),
  bad JSON, or bad UTF-8;
- a channel with no `id`, or two channels with the same `id` (favourites and
  history are stored by id);
- a schedule whose `epoch` (the start date the running order is counted from)
  does not parse or has no time zone;
- a channel with fewer than 2 items;
- an item with an empty title, an address that is not `https://`, `seconds`
  that is not a whole number above zero, or an address repeated in the channel;
- an item with no `credit` on any channel that is not on the public-domain list
  (`publicDomainChannelIds` in the checker — today `nasa` and `ocean`). Creative
  Commons footage is only licensed on condition the credit is shown, so the rule
  is turned round: **every** item needs a credit unless its channel is on that
  list, and adding a channel to the list is a rights decision made in its own
  pull request;
- `version` not going up when the file changed;
- a channel removed, or a channel losing more than a fifth of its items, unless
  the pull request says `drop intended`.

It **warns, without failing**, when an existing channel's epoch changes or its
items are reordered, inserted or re-timed. Those are legitimate — but an
existing channel is a broadcast in progress, and any of them cuts every viewer
to a different point the moment the file is published. The report says so in
capitals; say in the pull request that you meant it.

Before judging the real file, the check runs `tools/validate_catalog_selftest.dart`,
which damages copies of the catalogue one rule at a time and insists each copy
is refused for its own reason. A checker that has quietly stopped checking is
worse than none, because its tick goes on being believed.

**Not checked** (so nobody assumes it is): whether an address actually plays
(the weekly sweep does that), whether `seconds` is the file's true length (that
is the curator's job, with `ffprobe`), and whether the rights are what the
credit says (that is the manifest).

## Turn on the merge lock — the owner's one-time clicks

GitHub only greys out the Merge button if it is told to, and by default the
rules do **not** apply to the repository's administrator — which is you. Do
this once, **after** the pull request that adds the workflows has been merged
and the `validate` check has run at least once (the check only becomes
selectable after GitHub has seen it run):

1. On github.com open **ribfeast/free-tv-catalog → Settings → Branches →
   Add branch ruleset** (or *Add classic branch protection rule*), and type
   `main` as the branch name.
2. Tick **Require a pull request before merging**. Then **untick "Require
   approvals"** — GitHub never lets you approve your own pull request, so with
   that box on, a one-person project can never merge.
3. Tick **Require status checks to pass before merging**, and in the search box
   pick **`validate`**. (If it is not offered, the check has not run yet: open
   any pull request first, wait for the tick, then come back.)
4. Tick **Do not allow bypassing the above settings** (in a ruleset: leave the
   *Bypass list* empty). **Without this the rule does not bind you**, and a
   direct push to main still goes through.
5. Save.

To prove it took: push a branch with a deliberately broken `catalog.json`
(delete a comma), open a pull request, and see the Merge button greyed out with
a red `validate`. Close it without merging.

## The weekly stream sweep, and the 60-day trap

`bash check-streams.sh` probes every address in the file. It follows a
*variant* playlist, not just the master — a dead feed can serve a healthy-looking
master from a CDN's cache while everything behind it is gone, and four channels
once sat dead here for exactly that reason. Run it yourself before publishing a
change; the `streams` workflow runs it every Monday.

**GitHub disables scheduled workflows on a public repository after 60 days with
no commits or pull requests.** This repository can easily go two months without
a change — exactly when streams rot unnoticed. The working rule: anyone
touching the catalogue looks at the date of the last `streams` run on the
Actions tab and treats anything older than 8 days as a failure. If GitHub has
switched it off, the workflow's page shows an *Enable workflow* button; press
it, or run it by hand with *Run workflow*.

The first run should be compared with a run of `check-streams.sh` at home: the
video hosts may answer GitHub's servers differently from a home connection.

## The format

```jsonc
{
  "version": 8,                     // whole number; goes UP on every change
  "updated": "2026-09-19",          // note to yourself; any text
  "channels": [
    {                               // a channel we run ourselves: a running order
      "id": "earth",                // stable, unique; favourites stick to it
      "name": "Earth",
      "category": "Science",
      "kind": "scheduled",
      "schedule": {
        "epoch": "2026-09-19T00:00:00Z",   // when the loop started; needs the Z
        "items": [
          { "title": "Arctic Sea Ice Minimum 2023",
            "url": "https://…/arctic_sea_ice_2023.mp4",
            "seconds": 107,         // true length, from ffprobe or the source API
            "year": 2023,           // optional
            "credit": "NASA/SVS",   // required unless the channel is public domain
            "description": "…",     // optional; original title for translations
            "aspect": 1.778 }       // optional; only when the pixels lie
        ]
      }
    },
    {                               // a live stream
      "id": "apple_test",
      "name": "Apple Test",
      "category": "Test",
      "streamUrl": "https://…/master.m3u8"
    }
  ]
}
```

A channel has **either** a `streamUrl` **or** a `kind: "scheduled"` with a
`schedule` — never both. Everyone sees the same programme at the same time
because each phone works out what is on air from `epoch`, the item lengths and
the clock; there is no streaming server.

## ⚠️ Only add channels we are allowed to redistribute

This is the rule that keeps the app in the stores:

- ✅ Channels from their **owner/distributor**, **public-domain**,
  **Creative Commons** (with the credit shown), or **creator** feeds — each with
  a manifest recording the rights basis per clip.
- ❌ Do **not** paste channels rebundled from other platforms (Pluto, Samsung TV
  Plus, etc.). "Free to watch there" is **not** "licensed for us to redistribute".
- ❌ The Internet Archive's licence field is set by the uploader, not checked.
  It is not a rights basis.

Today's channels: *Space*, *Deep Sea* and *Earth* (NASA and NOAA footage — US
federal government works, public domain by statute), *Night Sky* (ESO and NSF
NOIRLab, CC BY) and *Animation* (Blender open movies and one Morevna film,
CC BY / CC BY-SA), plus Apple's official test stream.
