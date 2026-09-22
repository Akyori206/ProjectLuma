# Notes for Claude Code

## Shape of the app
- The whole website is `site/index.html`: one `<style>` block, the page shell, then one `<script>` with all the JavaScript. No framework, no bundler, no dependencies.
- The script runs top to bottom in these parts: helpers and constants (including the saved news snapshot `FF`), sample-data generator, local storage and IndexedDB media store, then views (journal, trade panel, dashboard, habits), then the Backtest tab and Luma voice assistant, Winners vs losers, news, chat, then accounts and sync (`cloud`, Supabase REST calls via `sb()`), and finally the action map, event wiring and `init()`.
- State lives in one object `S`, saved with `persist()` to localStorage under a per-user key and synced to Supabase table `user_data` (one JSON document per user). Screenshots, icons and videos go to IndexedDB and the private Supabase storage bucket `media`.
- UI is plain template strings. `render()` redraws the current view. Clicks are handled by delegation: elements carry `data-act="name"` and the handler is `A['name']` in the action map.
- Supabase connection: `CLOUD_CONFIG` near the start of the accounts section. Publishable key only.
- AI: inside claude.ai the page uses `window.claude.use('sample')`; on the hosted site it uses the user's own Anthropic key through `makeKeyAI()` (direct browser call). Luma still works without AI using built-in parsing.
- News: `loadNews()` calls the `news` edge function; the embedded `FF` rows are only a fallback.

## Rules
- Never commit or paste secret keys (Supabase secret or service_role keys, Anthropic keys).
- Keep `extras/claude-link-version.html` separate: it is a different build without accounts.
- After editing, check the script still parses (for example, extract the `<script>` contents and run `node --check`), then test in Chrome, including sign-in, the Backtest tab and the News tab.
- Database changes go in `supabase/setup.sql` (written to be safe to re-run) as well as the live project.
