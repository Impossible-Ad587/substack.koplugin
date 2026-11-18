# Substack for KOReader (v2.5)

Read Substack on your e-reader. New posts sync to your device as proper e-books, you read through an Inbox, and finished articles clear themselves away.

## Install / update

1. Delete any old `substack.koplugin` folder, then copy the new one into KOReader's `plugins` folder:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/`
   - PocketBook: `/applications/koreader/plugins/`
   - Android: `koreader/plugins/`
2. Restart KOReader.
3. Open the top menu → 🛠 **Tools** → **More tools** → **Substack**.

Articles you saved with version 1 (HTML files) still show up and still open. New downloads are EPUBs.

## Getting started (2 minutes)

1. **Account → Sign in with an email code** (or email & password), then **Import** your subscriptions and the people you follow.
   (Or add publications by hand under **Publications → + Add publication…**)
2. **Sync now**. New posts from the last 7 days download in the background (change this under **Settings → Download posts from**).
3. Open **Inbox** and start reading.
4. **Optional:** in **Settings**, turn on **Sync automatically when Wi-Fi connects** and **Auto-delete finished articles**.

## The daily routine

| | |
|---|---|
| **Inbox** | Grouped by writer: a heading with the publication's name and the writer's Substack username, plus how many are new, with that writer's articles listed underneath. Tap a heading to fold it (▸) or open it again (▾), or use **Collapse all / Expand all**. Long-press a heading to see only that writer. Tap **Grouped by writer** at the top to switch to one list. Also at the top: **Sort** (newest, oldest, shortest, by publication), **Short reads** (only articles you can finish in 5/10/15 minutes), **Sync now** and **Mark all as finished…**. **Read next** goes in-progress first, then newest. |
| **Sync now** | Fetches new posts from every publication you follow, plus posts you bookmarked in the Substack app (when signed in). Tap the progress message to stop. |
| **When you finish an article** | A prompt offers **Read next**, **Back to my book**, **Inbox**, **Keep**, **Delete article**, **Close article** or **Stay on this page**. Turn it off in Settings to get KOReader's usual end-of-book screen. |
| **Long-press an Inbox article** | Mark finished/unread · Re-download · Keep (never auto-delete) · Follow its publication · Delete |
| **My reading (stats)** | A dashboard of your reading: articles and time this week and in total, streaks, the publications and writers you read most, which days and times you read, and what article length you prefer, plus a few plain-language observations. It opens like an article and is never added to your bookshelf or history. |

## Everything else

- **Publications vs. people you follow**: on Substack these are two separate things. *Subscribing* puts a publication in your inbox; *following* a person is a profile follow (their Notes and posts in the Substack app). **Import my subscriptions & the people I follow** brings in both: each person's own publication is added (labelled with their Substack username), and people without a publication of their own go under **Publications → People you follow**, where their posts are picked up from their profile on every sync. Notes aren't articles, so they're skipped.
- **Publications**: tap one to see its posts. This works offline from the last sync, with **Refresh** to update. Long-press a publication to **mute** it (its posts stay out of your Inbox, Latest and syncs, but you can still browse it here), turn auto-download on/off, see what it recommends, or unfollow.
- **Latest from all publications**: one combined list across everything you follow.
- **Saved on Substack (from your phone)**: posts you bookmarked in the Substack app. Save on your phone, read on the e-reader. *Experimental: it uses an unofficial Substack feature.*
- **Discover**
  - **Search publications**: requires signing in, because Substack only allows search for signed-in users.
  - **Recommended for you**: publications the ones you follow recommend, ranked by how many recommend them.
  - In any list: tap to preview, long-press to follow.
- **Library**
  - **Archive** (finished), **Kept & highlighted**, **All saved articles**.
  - **Digests** and **Make a digest**: bundles unread articles into one magazine-style EPUB with a table of contents. Afterwards it offers to move those articles to the Archive. Turn on **Settings → Weekly digest** to get one automatically every Monday.
  - **Export highlights (Markdown)**: every highlight and note from your Substack articles in one file, each with the article title, author, publication and link. Ready for Notion, Obsidian or anywhere that reads Markdown.
  - **Back up publications & settings** / **Restore from backup or OPML…**: saves your publication list and settings (never your sign-in). The `.opml` file also works in other feed readers, and you can restore from an OPML exported by another reader.
  - **Storage**: shows space used, and offers **Delete finished articles now**.
- **Settings**: **download posts from** the last 12 hours / 1, 3, 7 (default), 14, 30 or 90 days / any date / a custom number of days (older posts are never downloaded automatically, which saves space; posts you bookmark in the Substack app always come through) · auto-sync on Wi-Fi · turn Wi-Fi off after syncing · weekly digest · new articles per sync across all publications (10/20/40/80) · new posts per publication per sync (1/3/5/10) · short-read length · images (standard/large/small/none; standard opens fastest without looking blurry) · comments (off by default/top 10/top 25; articles without comments get no Comments chapter) · podcast episodes (skipped by default, or show notes only, since KOReader can't play audio) · the "next unread" prompt · auto-delete finished articles (after 30 days by default; 7/30/90/never) · download folder · **Reset settings to defaults**.
- **Gestures**: ⚙ → Taps and gestures → Gesture manager → pick a gesture → General → **Substack: sync now / inbox / next unread article / latest posts / close article (back to list)**.
- **Closing an article** takes you back to the list you opened it from (a publication's posts, Inbox, Latest, Saved, Digests). While reading, the Substack menu's first item is **‹ Back to <list>**; you can also put it on a gesture (a corner tap or a two-finger swipe down works well).
- **Bookshelf users**: if the Bookshelf home screen plugin is installed, closing an article shows Bookshelf with your list on top, so Back from the list lands on Bookshelf instead of the file browser. Toggle under Settings → Return to Bookshelf after closing an article.
- **While reading an article**, the Substack menu also offers **Next unread article** and **Follow** (if you don't follow that publication yet).

## Following lots of publications

The plugin is built to stay pleasant with dozens of publications:

- **Each sync downloads at most 20 new articles** (adjustable), choosing the newest across everything you follow, so the Inbox never floods. Anything left out is still in **Publications**, and the sync summary tells you how many.
- **Finished articles clear themselves after 30 days.** Kept and highlighted ones are never deleted.
- **Downloads stop when the device is nearly full** (under 150 MB free), with a message saying what to clear.
- If Substack says it's getting too many requests, the plugin **waits and retries** instead of failing.
- If Wi-Fi was off when a sync started, it's **switched off again afterwards**.
- Menus stay quick with hundreds of saved articles, and the offline post lists are kept small (40 posts per publication).

## What the e-books look like

- One EPUB per article: publication name, title, subtitle, author, date and reading time at the top.
- Images are converted to e-ink-friendly JPEGs. Tiny decorative images are skipped.
- The post's cover image becomes the book cover, which shows up in KOReader's cover view.
- Footnotes open as pop-ups when tapped. Embedded videos and tweets become links.
- Optional comments are added as a separate chapter.
- Articles are tagged with the publication as the series, so KOReader's highlight export produces properly attributed notes (title, author, publication, link).
- Files are saved in `koreader/substack/<publication>/`, outside your home folder, so they don't show up among your books in the file browser or home-screen/shelf plugins. Digests go in `koreader/substack/Digests/`, exports and backups in `koreader/substack/Exports/` (copy them off over USB), and the stats page in `koreader/substack/Reports/`. Articles saved by an earlier version in `<home folder>/Substack` are moved there automatically.

Articles you keep **or highlight** are never auto-deleted.

## Signing in

**Easiest: Account → Sign in with an email code.** Substack only sends codes to a real web browser, so: on your phone, open substack.com/sign-in in the browser (not the Substack app), enter your email and ask for a code, but don't type it there. On the e-reader, enter your email, tap **Next**, and type the code. No password needed.

**Sign in with a cookie file (most reliable):** the plugin comes with a `substack_cookie.txt` file in its folder. Open it on a computer: the steps are written inside it. In short, copy your `connect.sid` value (older accounts: `substack.sid`) from your browser (Developer Tools → Application → Cookies → substack.com), paste it over the placeholder line, save the file as plain text, and copy it back into the `substack.koplugin` folder. Then choose **Account → Load session cookie from file**. The plugin checks the value with Substack, and offers to delete the file afterwards. You can also put the file at the top level of the device or in your KOReader home folder.

**Paste instead:** **Account → Paste session cookie (advanced)** takes the same value typed or pasted in.

**Check sign-in** (in Account) tells you whether Substack still accepts your session. If your sign-in expires, the next sync tells you.

The cookie route also works if Substack asks for a captcha when you sign in. Your password is never stored on the device, only the session. Treat the session like a password.

Substack renamed its session cookie from `substack.sid` to `connect.sid`. Version 2.5 handles both (2.4 only knew the old name, which is why code sign-in could fail with "Substack didn't accept your session"). The plugin now also tests the session before saying you're signed in.

## Known limitations

- It uses Substack's unofficial website endpoints, so it can break if Substack changes them.
- Email-code sign-in: Substack usually won't send the code when the Kindle asks for it. Request the code from a phone or computer browser, then type it into the Kindle (the plugin walks you through this).
- Paid posts need you to be signed in with an account that has access.
- Tested on a jailbroken Kindle Paperwhite only. Other devices that run KOReader should work but haven't been tested.
- If the Kindle goes to sleep while an article is open, that's the device's own sleep timer, not the plugin.

## Reset or uninstall

- **Reset:** with KOReader closed, delete `substack.lua`, `substack_library.lua`, `substack_cache.lua` **and their `.old` backups** from KOReader's `settings/` folder. KOReader quietly restores settings from the `.old` copies otherwise.
- **Downloaded articles** are in `koreader/substack/`. Delete that folder to remove them.
- **Uninstall:** do both of the above, then delete `plugins/substack.koplugin`.

## Notes

- Settings live in KOReader's `settings/` folder: `substack.lua`, `substack_library.lua`, `substack_cache.lua`.
