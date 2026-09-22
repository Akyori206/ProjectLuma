# TradeLens

Trading journal with a backtest voice assistant (Luma), a P&L dashboard and calendar, bad-habit tracking,
an auto-updating economic calendar, and accounts that sync across devices.

## What's in this repo

| Path | What it is |
|---|---|
| `site/index.html` | **The entire website.** All HTML, CSS and JavaScript in one file (3363 lines, ~288 KB). This is byte-for-byte the file running on Netlify. |
| `supabase/setup.sql` | Database setup: tables, row-level security, storage bucket, admin tools, news tables. Already applied to the live project. |
| `supabase/functions/news/index.ts` | The "news" edge function that refreshes the calendar from Forex Factory. Already deployed. |
| `netlify.toml` | Tells Netlify to publish only `site/`. |
| `extras/claude-link-version.html` | The separate copy that runs at the claude.ai artifact link (no accounts, AI through Claude). Not deployed to Netlify. |
| `CLAUDE.md` | Notes for Claude Code about how the code is organized. |

There is **no package.json, no npm install and no build step.** The site uses no packages: everything is plain
HTML, CSS and JavaScript in one file, and Google Fonts load from Google's servers. Open `site/index.html` or
upload the `site` folder and it runs.

## Services it uses

- **Supabase** (project `ioeltnbqlwfdfxwphstv`): sign-in, the synced journal data, screenshot storage, the news table and the news function.
  The Project URL and *publishable* key are in `site/index.html` (search `CLOUD_CONFIG`). Both are designed to be public.
  Never put a secret key (`sb_secret_...`) or `service_role` key in this repo.
- **Anthropic API**: optional. Each person pastes their own key in Settings; it stays in their browser and is never stored in the repo or database.
- **Forex Factory**: public weekly calendar export, fetched only by the news function.

## Deploy

- **Website:** Netlify publishes the `site` folder. Once this repo is connected to Netlify, every push to `main` redeploys automatically.
- **Database:** `supabase/setup.sql` is safe to re-run in the Supabase SQL Editor.
- **News function:** `supabase functions deploy news --project-ref ioeltnbqlwfdfxwphstv` (needs the Supabase CLI; keep JWT verification on).

## Not stored in this repo

User accounts and journal data live in Supabase; Netlify settings live in Netlify; API keys live in each user's browser.
