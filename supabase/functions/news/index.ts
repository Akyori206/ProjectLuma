// TradeLens news: serves the economic calendar and keeps it fresh from Forex Factory's public weekly export.
// Visitors never call Forex Factory directly: at most one refresh every 2 hours, shared by everyone.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const REFRESH_MS = 2 * 60 * 60 * 1000;   // pull new data at most every 2 hours
const RETRY_MS = 15 * 60 * 1000;         // after a failed pull, wait 15 minutes
const SOURCES = [
  ["https://nfs.faireconomy.media/ff_calendar_thisweek.json", "https://nfs.faireconomy.media/ff_calendar_thisweek.xml"],
  ["https://nfs.faireconomy.media/ff_calendar_nextweek.json", "https://nfs.faireconomy.media/ff_calendar_nextweek.xml"],
];
const IMPACT: Record<string, string> = { high: "high", medium: "medium", low: "low", holiday: "holiday", "non-economic": "holiday" };

const etFmt = new Intl.DateTimeFormat("en-CA", {
  timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", hourCycle: "h23",
});
function etParts(d: Date) {
  const p = Object.fromEntries(etFmt.formatToParts(d).map((x) => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour}:${p.minute}` };
}
type Row = { id: string; date: string; time: string; country: string; title: string; impact: string; forecast: string; previous: string; event_at: string };
function row(title: string, country: string, at: Date, impactRaw: unknown, forecast: unknown, previous: unknown): Row | null {
  if (!title || isNaN(at.getTime())) return null;
  const impact = IMPACT[String(impactRaw ?? "").trim().toLowerCase()] ?? "low";
  const { date, time } = etParts(at);
  return {
    id: `${country}|${title}|${at.toISOString()}`, date, time: impact === "holiday" ? "00:00" : time,
    country, title, impact, forecast: String(forecast ?? "").trim(), previous: String(previous ?? "").trim(), event_at: at.toISOString(),
  };
}
function fromJson(arr: unknown): Row[] {
  if (!Array.isArray(arr)) return [];
  return arr.map((e: any) => row(String(e?.title ?? "").trim(), String(e?.country ?? "").trim(), new Date(e?.date), e?.impact, e?.forecast, e?.previous)).filter(Boolean) as Row[];
}
function fromXml(xml: string): Row[] {
  const out: Row[] = [];
  for (const m of xml.matchAll(/<event>([\s\S]*?)<\/event>/g)) {
    const g = (t: string) => { const x = m[1].match(new RegExp(`<${t}>(?:<!\\[CDATA\\[)?([\\s\\S]*?)(?:\\]\\]>)?</${t}>`)); return x ? x[1].trim() : ""; };
    const [mo, da, yr] = g("date").split("-").map(Number);
    if (!yr) continue;
    let hh = 0, mm = 0;
    const tm = g("time").match(/(\d{1,2}):(\d{2})\s*(am|pm)/i);
    if (tm) { hh = (+tm[1] % 12) + (tm[3].toLowerCase() === "pm" ? 12 : 0); mm = +tm[2]; }
    const r = row(g("title"), g("country"), new Date(Date.UTC(yr, mo - 1, da, hh, mm)), g("impact"), g("forecast"), g("previous"));
    if (r) out.push(r);
  }
  return out;
}
async function pull(urls: string[]): Promise<Row[] | null> {
  for (const u of urls) {
    try {
      const r = await fetch(u, { headers: { "User-Agent": "TradeLens calendar sync" }, signal: AbortSignal.timeout(10000) });
      if (!r.ok) continue;
      const txt = await r.text();
      const rows = u.endsWith(".json") ? fromJson(JSON.parse(txt)) : fromXml(txt);
      if (rows.length) return rows;
    } catch (_e) { /* try the next format */ }
  }
  return null;
}
async function refresh(db: any): Promise<number> {
  let saved = 0;
  for (const urls of SOURCES) {
    const rows = await pull(urls);
    if (!rows) continue;
    const dates = rows.map((r) => r.date).sort();
    const { error } = await db.rpc("replace_news", { p_from: dates[0], p_to: dates[dates.length - 1], p_rows: rows });
    if (!error) saved += rows.length;
  }
  return saved;
}
const isoDay = (d: Date) => d.toISOString().slice(0, 10);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json", "cache-control": "private, max-age=300" } });
  try {
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const url = new URL(req.url), dayRe = /^\d{4}-\d{2}-\d{2}$/, now = Date.now();
    let from = url.searchParams.get("from") ?? "", to = url.searchParams.get("to") ?? "";
    if (!dayRe.test(from)) from = isoDay(new Date(now - 35 * 864e5));
    if (!dayRe.test(to)) to = isoDay(new Date(now + 70 * 864e5));
    if (Date.parse(to) - Date.parse(from) > 180 * 864e5) to = isoDay(new Date(Date.parse(from) + 180 * 864e5));

    const { data: meta } = await db.from("news_meta").select("fetched_at,checked_at").eq("id", 1).maybeSingle();
    const last = meta?.fetched_at ? Date.parse(meta.fetched_at) : 0, checked = meta?.checked_at ? Date.parse(meta.checked_at) : 0;
    if (now - last > REFRESH_MS && now - checked > RETRY_MS) {
      await db.from("news_meta").upsert({ id: 1, checked_at: new Date().toISOString(), fetched_at: meta?.fetched_at ?? null });
      const saved = await refresh(db);
      await db.from("news_meta").upsert(saved > 0
        ? { id: 1, checked_at: new Date().toISOString(), fetched_at: new Date().toISOString(), ok: true, rows: saved }
        : { id: 1, checked_at: new Date().toISOString(), fetched_at: meta?.fetched_at ?? null, ok: false, rows: 0 });
    }

    const { data: events, error } = await db.from("news_events")
      .select("date,time,country,title,impact,forecast,previous")
      .gte("date", from).lte("date", to).order("date").order("time").limit(3000);
    const { data: m2 } = await db.from("news_meta").select("fetched_at,ok").eq("id", 1).maybeSingle();
    if (error) return json({ events: [], fetched_at: m2?.fetched_at ?? null, ok: false }, 500);
    return json({ events: events ?? [], fetched_at: m2?.fetched_at ?? null, ok: m2?.ok ?? null });
  } catch (e) {
    return json({ events: [], fetched_at: null, ok: false, error: String(e) }, 500);
  }
});
