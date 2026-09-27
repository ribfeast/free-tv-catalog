# Free TV — live channel catalogue

`catalog.json` on the **main** branch of this repository is the channel list
every installed copy of the app reads. The app re-fetches it on launch and swaps
in whatever it finds, within a few minutes of a merge. **Merging to main is
therefore a release**: no App Store review, no update, no undo button on the
phones that have already fetched it.

> The app also ships with a copy of this list baked in (the "seed"), so it works
> on first launch and offline. This hosted file is what lets channels change
> **after** the app is published.

Three things guard the file:

- **`validate`** — a check that runs on every pull request (again whenever its
  description is edited) and on every push to main
  (`.github/workflows/validate.yml`). It refuses a file the app could read
  wrongly, shouts about changes that move what is on air, and on a pull request
  **test-plays every stream address the change adds**. The merge lock (below)
  greys out the Merge button until it passes.
- **`published`** — after every merge, a job in the same workflow asks the live
  address every 20 seconds, for up to 10 minutes, until it serves the merged
  `version`. Green means phones are being given the new list; red says plainly
  that they are not yet.
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
   by one**. Run the checker yourself before pushing, comparing with the file
   phones are reading now (in PowerShell; the download keeps the file's bytes
   exactly as they are, which `git show ... > file` in PowerShell 5.1 does not):

   ```
   Invoke-WebRequest -UseBasicParsing -Uri https://raw.githubusercontent.com/ribfeast/free-tv-catalog/refs/heads/main/catalog.json -OutFile "$env:TEMP\live-catalog.json"
   dart tools/validate_catalog.dart catalog.json "$env:TEMP\live-catalog.json"
   ```

   (Dart comes with Flutter: `C:\Users\james\flutter\bin\dart`.) Read its
   summary — channel and item counts, hours per channel, what changed.
4. **Pull request.** Push the branch and open a pull request. The `validate`
   check runs; its report is on the run's summary page, including the
   test-play of every address the change adds (each is tried twice, a minute
   allowed each time; a dead one is named with its host). If the change
   removes a channel or a big share of one channel's items, or raises a
   channel's `requires`, **on purpose**, write the words `drop intended` in the
   pull request description, or the check refuses it. Editing the description
   is enough — the check runs again by itself, no new commit needed. (After the
   merge, the push to main runs the check once more; it cannot see the
   description, so it reports the drop as a warning rather than refusing it —
   the pull request was the gate.)
5. **Merge — the owner does this.** Merging is the deploy. Afterwards the
   `published` job (Actions tab, on the merge) waits until the live address
   serves the new `version`, and goes green when it does. To look yourself:

   ```
   dart tools/live_version.dart
   ```

   prints the version the live address serves right now (it can lag up to 5
   minutes behind a merge). Until that number is seen, nothing has been
   published — two channels once sat finished on a branch for 13 days.
6. **Seed.** Copy the merged file over the app's bundled seed
   (`app/assets/free_tv_catalog.json`) so a fresh install starts with the same
   channels.

## Roll back — put the last good channel list back

Use this when a merged change turns out to be bad: a channel that only spins,
the wrong programmes, or no channels at all. It puts back the last file that
was good, under a **new** version number, through the same pull request and
check as any other change. Allow about fifteen minutes, most of it waiting for
the check and the file server.

**Do not use GitHub's Revert button.** It puts back the old file *with its old
version number*, and the check refuses a file whose version did not go up (the
number is how anyone can tell which list a phone, or the live address, is
serving). A rollback is the old file under the next number.

Phones pick up the good list the next time the app is opened; a phone that
already fetched the bad one keeps it until then.

Open **Windows PowerShell** and keep that one window open to the end — later
steps reuse numbers that earlier steps remember. Paste one block at a time and
read its **Check** before going on.

1. Go to the catalogue folder, make sure nothing is half-done there, and bring
   main up to date.

   ```
   cd C:\Users\james\free-tv-catalog; git status --short
   ```

   **Check:** it prints nothing. If it lists files, stop — something
   unfinished is sitting in this folder, and git would refuse the next step.

   ```
   git switch main; git pull; $main = (Get-Content -Raw -Encoding UTF8 catalog.json | ConvertFrom-Json).version; "main is at version $main"
   ```

   **Check:** the last line is `main is at version 9` (your number): the
   version of the bad list.

2. Find the last good version. This lists the channel lists main has served,
   newest first, each with its version:

   ```
   git log --first-parent --format="%h %ad %s" --date=short -8 -- catalog.json | ForEach-Object { $v = (git show "$($_.Split(' ')[0]):catalog.json" | Select-String '"version"' | Select-Object -First 1).Line -replace '\D', ''; "version $v   $_" }
   ```

   (`--first-parent` is not optional. Without it the list also shows the
   commits from *inside* each pull request, which were never live, and one
   of them can hold the bad change under the old version number: picked by
   mistake, it passes every check and publishes the bad list again.)

   Each line is a list that main actually served. The top line is the bad
   one (main's version). The good one is normally the line **just below the
   top**; its description will usually read `Merge pull request #N ...` (the
   oldest lines, from before changes went through pull requests, read like
   `Add "Earth" (version 8)`). If the bad change arrived in more than one
   pull request, go down to the line just below the first of them. Put that
   line's commit (the 7 characters after the version) into `$good`, in place
   of `a66ad2b` below:

   ```
   $good = 'a66ad2b'; git show --no-patch --format="%h %s" $good
   ```

   **Check:** it prints that commit and its description again. An error means
   the 7 characters were copied wrong.

3. Make a branch and put that file back.

   ```
   git switch -c "rollback/to-$good"; git restore --source $good -- catalog.json; git status --short
   ```

   **Check:** the last line is ` M catalog.json`, and nothing else is listed.

4. Give it the next number: the live version plus one. First fetch the file
   phones are reading now:

   ```
   Invoke-WebRequest -UseBasicParsing -Uri https://raw.githubusercontent.com/ribfeast/free-tv-catalog/refs/heads/main/catalog.json -OutFile "$env:TEMP\live-catalog.json"; $live = (Get-Content -Raw -Encoding UTF8 "$env:TEMP\live-catalog.json" | ConvertFrom-Json).version; "live: $live   main: $main"
   ```

   **Check:** the two numbers are the same. If `live` is lower, the bad change
   has not even reached phones yet: wait five minutes and run this block again.

   Then write the new number into the restored file. (It is written with .NET
   rather than `Set-Content` on purpose: PowerShell 5.1's `Set-Content` adds
   the invisible marker that once made this file unreadable to every phone.)

   ```
   $new = $live + 1; $path = (Resolve-Path catalog.json).Path; $text = [IO.File]::ReadAllText($path); $text = ([regex]'"version":\s*\d+').Replace($text, '"version": ' + $new, 1); [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)); "new version: $new"
   ```

   **Check:** it prints `new version: 10` (live plus one).

5. Run the checker, comparing with the live file.

   ```
   dart tools/validate_catalog.dart catalog.json "$env:TEMP\live-catalog.json"
   ```

   **Check:** under WHAT CHANGED it says `version 9 -> 10` (your numbers) and
   the last line is `RESULT: PASS`. Warnings in capitals about what is on air
   are expected — a rollback moves programmes on purpose.

   If the last line is `RESULT: FAIL`, read the FAILURES:
   - A failure saying a channel `is REMOVED`, `falls from N to M items`, or
     `now needs app feature level` is a **drop**: the good file lacks
     something the bad one added. That is normal when undoing an addition. Run
     the same command again with ` --allow-drop` added at the end. It must now
     end in `RESULT: PASS`, and you **must** write `drop intended` in step 7.
   - Anything else: stop. The old file is refused by today's rules and cannot
     go out as it is; ask a Claude session to fix it on this branch.

6. Save the branch on GitHub.

   ```
   git add catalog.json; git commit -m "Roll back catalog.json to $good as version $new"; git push -u origin "rollback/to-$good"
   ```

   **Check:** the output includes `check-secrets: clean` and a line ending in
   `-> rollback/to-` and the 7 characters.

7. Open the pull request. On github.com, open **ribfeast/free-tv-catalog**; a
   yellow bar offers **Compare & pull request** for the rollback branch — press
   it. In the description, say what went wrong. **If step 5 found a drop, write
   the words `drop intended` anywhere in the description** — the check looks
   for exactly those two words, one space apart; capitals do not matter. Press
   **Create pull request**.

   **Check:** the `validate` check turns green. It can take several minutes:
   addresses the bad change had removed are "new" again and are test-played.
   If it goes red, press **Details** — the report says why. Forgot `drop
   intended`? Edit the description; the check runs again by itself.

8. Merge: **Merge pull request**, then **Confirm merge** — only with the green
   tick. Then, back in the same PowerShell window:

   ```
   dart tools/live_version.dart --wait-for $new
   ```

   **Check:** within 10 minutes it prints `PUBLISHED: the live address serves
   version 10` (your number). The `published` job on the Actions tab says the
   same. Until then, phones are still being given the bad list.

9. Tidy up.

   ```
   git switch main; git pull; git branch -d "rollback/to-$good"; git status --short
   ```

   **Check:** the last command prints nothing. (GitHub deletes its copy of the
   branch by itself after the merge.)

10. If the bad list had also been copied into the app's bundled seed
    (`app/assets/free_tv_catalog.json` in the app repo), copy this file over
    the seed too, as in step 6 of *How to change channels*.

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
- a `requires` that is not a whole number of 1 or more (see *The format*);
- `version` not going up when the file changed;
- a channel removed, a channel losing more than a fifth of its items, or a
  channel whose `requires` goes up (older app builds stop showing it, which to
  them is a removal), unless the pull request says `drop intended`.

It **warns, without failing**, when an existing channel's epoch changes or its
items are reordered, inserted or re-timed. Those are legitimate — but an
existing channel is a broadcast in progress, and any of them cuts every viewer
to a different point the moment the file is published. The report says so in
capitals; say in the pull request that you meant it.

Once the real file has been judged, the check also runs
`tools/validate_catalog_selftest.dart`, which damages copies of the catalogue
one rule at a time and insists each copy is refused for its own reason. A
checker that has quietly stopped checking is worse than none, because its tick
goes on being believed. (It runs *after* the checker so that a broken file is
reported as a broken file, not as a broken checker.)

A pull request's check then **test-plays the addresses the change adds** —
only those, compared with main — with `check-streams.sh` (see *The weekly
stream sweep*): 60 seconds allowed per request, one retry, four at a time. It
runs `tools/network_checks_selftest.dart` first, which serves a working video,
a missing one, one that never answers, a stream with a dead picture and more
from a small web server on the runner itself, and insists the stream check
(and the `published` check) say the right thing about each.

**Not checked** (so nobody assumes it is): whether an address that was already
in the file *still* plays (the weekly sweep does that), whether a test-played
video is the right video, whether `seconds` is the file's true length (that is
the curator's job, with `ffprobe`), and whether the rights are what the credit
says (that is the manifest).

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

Each dead address is reported with the reason (`HTTP 404`, `host not found`,
`no answer within 30 s`, ...) and its host, and the summary counts dead
addresses per host: when one host has many, the host is the problem (slow or
down), not the addresses. `bash check-streams.sh --new-since <other file>`
checks only the addresses that are not in the other file — that is what a pull
request's check runs — and `--timeout`, `--retries` and `--jobs` are explained
at the top of the script.

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
      "streamUrl": "https://…/master.m3u8",
      "requires": 2                 // optional; see below
    }
  ]
}
```

A channel has **either** a `streamUrl` **or** a `kind: "scheduled"` with a
`schedule` — never both. Everyone sees the same programme at the same time
because each phone works out what is on air from `epoch`, the item lengths and
the clock; there is no streaming server.

**`requires`** (optional, on a channel) is the lowest *catalogue feature level*
an app build must have to show the channel. Each app build knows its own level
(`catalogueFeatureLevel`, 1 today) and **skips any channel whose `requires` is
higher**. Leave it out when every build can show the channel. It exists because
this one file is read by every app version ever installed: when a new build
learns something new about the file (the way `aspect` was added — a build that
ignores it draws some clips squashed), that build goes up a level, and a channel
that is only right with the new understanding gets `"requires": 2`, so older
phones leave it out instead of showing it wrong. Two limits: builds made
*before* the field existed do not read it and show the channel anyway (no store
build has shipped yet, so every store build will read it); and raising it on a
channel that is already live takes that channel away from every older build,
so the check treats it as a drop.

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
