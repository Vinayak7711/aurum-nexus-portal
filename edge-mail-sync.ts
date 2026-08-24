// AURUM NEXUS · mail-sync — pulls new mail for one mailbox via Hostinger POP3S.
// Auth: caller's Supabase session token; access re-checked against mail.mailboxes RLS.
// Password comes from the vault secret MAIL_PASS_<KEY> (punctuation normalised to
// underscores, matched case-insensitively); it never leaves this function.
// Parses the full MIME tree so BOTH the readable body AND any attachments are captured;
// attachments are stored (base64) in mail.attachments and shown/downloaded in the ERP.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, apikey, content-type" };
const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json", ...CORS } });

const MAX_ATT = 20 * 1024 * 1024;   // skip a single attachment larger than 20 MB
const MAX_ATTS = 20;                // at most 20 attachments kept per message

class Pop {
  conn!: Deno.TlsConn; buf = ""; dec = new TextDecoder(); enc = new TextEncoder();
  async connect(host: string) { this.conn = await Deno.connectTls({ hostname: host || "pop.hostinger.com", port: 995 }); await this.line(); }
  async fill() { const b = new Uint8Array(16384); const n = await this.conn.read(b); if (n === null) throw new Error("closed"); this.buf += this.dec.decode(b.subarray(0, n)); }
  async line(): Promise<string> { while (!this.buf.includes("\r\n")) await this.fill(); const i = this.buf.indexOf("\r\n"); const l = this.buf.slice(0, i); this.buf = this.buf.slice(i + 2); return l; }
  async cmd(c: string): Promise<string> { await this.conn.write(this.enc.encode(c + "\r\n")); const l = await this.line(); if (!l.startsWith("+OK")) throw new Error(c.split(" ")[0] + " failed: " + l.slice(0, 80)); return l; }
  async multi(): Promise<string[]> { const out: string[] = []; while (true) { const l = await this.line(); if (l === ".") break; out.push(l.startsWith("..") ? l.slice(1) : l); } return out; }
  close() { try { this.conn.close(); } catch (_) { /* done */ } }
}

// ---------- MIME decode helpers ----------
function decWord(s: string): string {
  return s.replace(/=\?([^?]+)\?([BbQq])\?([^?]*)\?=/g, (_m, _cs, t, d) => {
    try {
      if (t.toUpperCase() === "B") return new TextDecoder().decode(Uint8Array.from(atob(d), c => c.charCodeAt(0)));
      return new TextDecoder().decode(Uint8Array.from(d.replace(/_/g, " ").replace(/=([0-9A-Fa-f]{2})/g, (_x: string, h: string) => String.fromCharCode(parseInt(h, 16))), (c: string) => c.charCodeAt(0)));
    } catch (_) { return d; }
  });
}
function decQP(s: string): string {
  return s.replace(/=\r?\n/g, "").replace(/=([0-9A-Fa-f]{2})/g, (_m, h) => String.fromCharCode(parseInt(h, 16)));
}
// base64 of raw bytes (used only when an attachment is NOT already base64 in the wire)
function b64FromBytes(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 8192) bin += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(bin);
}
function qpToBytes(s: string): Uint8Array {
  const t = s.replace(/=\r?\n/g, "");
  const out: number[] = [];
  for (let i = 0; i < t.length; i++) {
    if (t[i] === "=" && i + 2 < t.length && /[0-9A-Fa-f]{2}/.test(t.substr(i + 1, 2))) { out.push(parseInt(t.substr(i + 1, 2), 16)); i += 2; }
    else out.push(t.charCodeAt(i) & 0xff);
  }
  return new Uint8Array(out);
}
function stripHtml(s: string): string {
  return s.replace(/<style[\s\S]*?<\/style>/gi, "").replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<\/(p|div|tr|h[1-6]|li)>/gi, "\n").replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/\n{3,}/g, "\n\n").trim();
}

type Att = { filename: string; contentType: string; b64: string; size: number };
type Parsed = { from: string | null; to: string | null; subject: string | null; date: string | null; msgId: string | null; body: string; atts: Att[] };

// Recursively walk one MIME part, collecting the best text body and every attachment.
function walk(raw: string, acc: { text: string; html: string; atts: Att[] }) {
  const cut = raw.indexOf("\r\n\r\n");
  const rawHead = cut >= 0 ? raw.slice(0, cut) : raw;
  const head = rawHead.replace(/\r\n[ \t]+/g, " ");   // unfold folded headers
  const body = cut >= 0 ? raw.slice(cut + 4) : "";
  const hv = (n: string) => { const m = head.match(new RegExp("^" + n + ":[ \t]*(.*)$", "im")); return m ? m[1].trim() : ""; };
  const ctype = hv("Content-Type") || "text/plain";
  const mLower = ctype.toLowerCase();
  const disp = hv("Content-Disposition");
  const cte = hv("Content-Transfer-Encoding").toLowerCase();

  // multipart container → recurse into each child part
  const bMatch = ctype.match(/boundary="?([^";]+)"?/i);
  if (mLower.startsWith("multipart/") && bMatch) {
    const segs = body.split("--" + bMatch[1]);
    for (let seg of segs) {
      seg = seg.replace(/^\r\n/, "");
      if (!seg || seg === "--\r\n" || seg.startsWith("--")) continue;   // preamble / closing --boundary--
      walk(seg, acc);
    }
    return;
  }

  // leaf part — attachment or inline text
  const fnMatch = disp.match(/filename\*?="?([^";]+)"?/i) || ctype.match(/name\*?="?([^";]+)"?/i);
  const isAttachment = /attachment/i.test(disp) || (!!fnMatch && !mLower.startsWith("text/"));
  if (isAttachment && fnMatch) {
    if (acc.atts.length >= MAX_ATTS) return;
    let b64: string;
    if (cte.includes("base64")) {
      b64 = body.replace(/[^A-Za-z0-9+/=]/g, "");   // already base64 on the wire — keep as-is (cheap)
    } else if (cte.includes("quoted-printable")) {
      b64 = b64FromBytes(qpToBytes(body));
    } else {
      b64 = b64FromBytes(new TextEncoder().encode(body));
    }
    const size = Math.floor(b64.length * 3 / 4);
    if (!b64 || size > MAX_ATT) return;   // skip empty / oversized
    acc.atts.push({
      filename: decWord(fnMatch[1]).replace(/[\r\n"]/g, "").slice(0, 200) || "attachment",
      contentType: mLower.split(";")[0].trim() || "application/octet-stream",
      b64, size,
    });
    return;
  }

  // inline text part
  let content = body;
  if (cte.includes("base64")) { try { content = new TextDecoder().decode(Uint8Array.from(atob(body.replace(/\s/g, "")), c => c.charCodeAt(0))); } catch (_) { /* keep */ } }
  else if (cte.includes("quoted-printable")) content = decQP(body);
  if (mLower.startsWith("text/html")) { if (!acc.html) acc.html = content; }
  else if (mLower.startsWith("text/") || mLower === "text/plain") { if (!acc.text) acc.text = content; }
}

function parseMail(raw: string): Parsed {
  const cut = raw.indexOf("\r\n\r\n");
  const head = (cut >= 0 ? raw.slice(0, cut) : raw).replace(/\r\n[ \t]+/g, " ");
  const h = (n: string) => { const m = head.match(new RegExp("^" + n + ":[ \t]*(.*)$", "im")); return m ? decWord(m[1].trim()) : null; };
  const acc = { text: "", html: "", atts: [] as Att[] };
  walk(raw, acc);
  let body = acc.text || (acc.html ? stripHtml(acc.html) : "");
  if (!body) body = "(no readable text — open in webmail for the full message)";
  return { from: h("From"), to: h("To"), subject: h("Subject"), date: h("Date"), msgId: h("Message-ID"), body: body.slice(0, 20000), atts: acc.atts };
}

export default {
  fetch: async (req: Request) => {
    if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
    try {
      const auth = req.headers.get("authorization") || "";
      const { mailbox } = await req.json().catch(() => ({}));
      if (!mailbox) return J({ error: "Which mailbox?" }, 400);
      const url = Deno.env.get("SUPABASE_URL")!;
      const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
      // ---- cron mode: a scheduled job (pg_cron) authenticates with the shared CRON_SECRET
      const cronSecret = (Deno.env.get("CRON_SECRET") || "").trim();
      const gotSecret = (req.headers.get("x-cron-secret") || "").trim();
      const isCron = !!cronSecret && gotSecret === cronSecret;
      if (isCron && mailbox === "ALL") {
        // fan out: one sub-invocation per active mailbox, in parallel (each has its own time budget)
        const svc0 = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
        const { data: boxes } = await svc0.schema("mail").from("mailboxes").select("key").eq("is_active", true).order("key");
        const settled = await Promise.all((boxes || []).map(async (b: { key: string }) => {
          try {
            const r = await fetch(url + "/functions/v1/mail-sync", {
              method: "POST",
              headers: { "content-type": "application/json", "x-cron-secret": cronSecret, "apikey": anon },
              body: JSON.stringify({ mailbox: b.key }),
            });
            return [b.key, await r.json()];
          } catch (e) { return [b.key, { error: String(e).slice(0, 120) }]; }
        }));
        const results: Record<string, unknown> = {};
        let totalNew = 0;
        for (const [k, v] of settled as [string, { new_messages?: number }][]) { results[k] = v; totalNew += Number(v?.new_messages || 0); }
        return J({ ok: true, cron: true, total_new: totalNew, results });
      }
      let box: any = null;
      if (isCron) {
        const svcB = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
        const r = await svcB.schema("mail").from("mailboxes").select("*").eq("key", mailbox).maybeSingle();
        box = r.data;
      } else {
        const { data: claims } = await createClient(url, anon).auth.getClaims(auth.replace(/^Bearer /i, ""));
        const uid = claims?.claims?.sub;
        if (!uid) return J({ error: "Sign in first." }, 401);
        const userClient = createClient(url, anon, { global: { headers: { authorization: auth } } });
        // RLS answers the access question: the row is only visible if this user may open the box.
        const r = await userClient.schema("mail").from("mailboxes").select("*").eq("key", mailbox).maybeSingle();
        box = r.data;
      }
      if (!box) return J({ error: "You do not have access to this mailbox." }, 403);

      // Vault secret MAIL_PASS_<KEY> — normalise punctuation, match case-insensitively.
      const want = ("MAIL_PASS_" + String(box.key)).replace(/[^a-z0-9_]/gi, "_").toLowerCase();
      const envAll = Deno.env.toObject();
      let pass: string | undefined;
      for (const k in envAll) { if (k.toLowerCase() === want) { pass = envAll[k]; break; } }
      if (pass) pass = pass.trim();   // strip stray spaces / line-breaks from copy-paste
      if (!pass) return J({ error: "This mailbox is not connected yet — its password has not been added to the vault (secret MAIL_PASS_" + String(box.key).replace(/[^a-zA-Z0-9_]/g, "_") + ")." }, 424);

      const svc = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
      // Known ids: every message we already hold (any folder) + everything purged from Trash.
      const { data: known } = await svc.schema("mail").from("messages").select("id, pop_uidl, att_scanned").eq("mailbox_id", box.id).not("pop_uidl", "is", null);
      const { data: purged } = await svc.schema("mail").from("purged_uidls").select("pop_uidl").eq("mailbox_id", box.id);
      const seen = new Set([
        ...((known || []).map((r: { pop_uidl: string }) => r.pop_uidl)),
        ...((purged || []).map((r: { pop_uidl: string }) => r.pop_uidl)),
      ]);
      // Messages we already hold but never scanned for attachments (older mail synced before this feature).
      const unscanned = new Map<string, string>();   // uidl -> message id
      for (const r of (known || []) as { id: string; pop_uidl: string; att_scanned: boolean }[]) {
        if (r.pop_uidl && !r.att_scanned) unscanned.set(r.pop_uidl, r.id);
      }

      // store every attachment found in a parsed message
      const saveAtts = async (messageId: string, atts: Att[]) => {
        if (!atts.length) return;
        const rows = atts.map((a) => ({
          message_id: messageId, mailbox_id: box.id,
          filename: a.filename, content_type: a.contentType, size_bytes: a.size, data_b64: a.b64,
        }));
        await svc.schema("mail").from("attachments").insert(rows);
      };

      const secretName = "MAIL_PASS_" + String(box.key).replace(/[^a-zA-Z0-9_]/g, "_").toUpperCase();
      const popHost = (box as { pop_host?: string }).pop_host || "pop.hostinger.com";
      const isGmail = /gmail/i.test(popHost);
      const passHint = isGmail
        ? "this mailbox is on Google, so the secret must be a Google App Password (Google Account \u2192 Security \u2192 2-Step Verification \u2192 App passwords) \u2014 the normal Gmail password will NOT work, and POP must be switched on in Gmail Settings \u2192 Forwarding and POP/IMAP"
        : "it must exactly match this mailbox's Hostinger email password";
      let pop = new Pop();
      let fetched = 0, listed = 0, backfilled = 0;
      // Log in. Hostinger sometimes refuses even a CORRECT password when it is busy
      // (connection throttling), so a failed login is retried twice with a pause
      // before we conclude the password itself is wrong.
      let loggedIn = false, lastErr = "";
      for (let attempt = 1; attempt <= 3 && !loggedIn; attempt++) {
        try {
          await pop.connect(popHost);
          await pop.cmd("USER " + box.address);
          await pop.cmd("PASS " + pass);
          loggedIn = true;
        } catch (e) {
          lastErr = (e as Error).message || String(e);
          pop.close();
          pop = new Pop();
          if (attempt < 3) await new Promise((r) => setTimeout(r, attempt * 2500));
        }
      }
      if (!loggedIn) {
        if (/too many|try again|temporar|rate|busy|lock|timed? ?out|closed/i.test(lastErr)) {
          return J({ error: "The mail server is busy right now — this is temporary, NOT a password problem. Wait a minute and press ‘Check for new mail’ again." }, 424);
        }
        return J({ error: "The mail server refused this mailbox's password 3 times in a row, so the stored password is most likely wrong. Fix the secret " + secretName + " (Supabase → Edge Functions → Secrets) — " + passHint + " — no extra spaces. Server said: " + lastErr.slice(0, 90) }, 424);
      }
      try {
        await pop.cmd("UIDL");
        const uidls = (await pop.multi()).map(l => { const [n, u] = l.split(" "); return { n: Number(n), u }; });
        listed = uidls.length;

        // 1) brand-new messages (newest 30 per run)
        const fresh = uidls.filter(x => x.u && !seen.has(x.u)).slice(-30);
        for (const m of fresh) {
          await pop.cmd("RETR " + m.n);
          const raw = (await pop.multi()).join("\r\n");
          const p = parseMail(raw);
          const { data: ins, error } = await svc.schema("mail").from("messages").insert({
            mailbox_id: box.id, folder: "IN", pop_uidl: m.u, msg_id: p.msgId,
            from_addr: p.from, to_addr: p.to, subject: p.subject || "(no subject)",
            sent_at: p.date ? new Date(p.date).toISOString() : null, body_text: p.body,
            has_attachments: p.atts.length > 0, att_scanned: true,
          }).select("id").single();
          if (!error && ins) { await saveAtts(ins.id, p.atts); fetched++; }
        }

        // 2) backfill: older messages still on the server that predate attachment support (up to 12/run)
        const toBackfill = uidls.filter(x => x.u && unscanned.has(x.u)).slice(-12);
        for (const m of toBackfill) {
          const mid = unscanned.get(m.u)!;
          await pop.cmd("RETR " + m.n);
          const raw = (await pop.multi()).join("\r\n");
          const p = parseMail(raw);
          await saveAtts(mid, p.atts);
          await svc.schema("mail").from("messages").update({
            has_attachments: p.atts.length > 0, att_scanned: true,
          }).eq("id", mid);
          if (p.atts.length) backfilled++;
        }

        await pop.cmd("QUIT");
      } finally { pop.close(); }
      return J({ ok: true, mailbox, on_server: listed, new_messages: fetched, backfilled_with_attachments: backfilled });
    } catch (e) {
      const msg = (e as Error).message || String(e);
      if (/PASS failed|USER failed|AUTH/i.test(msg)) return J({ error: "The mail server refused this mailbox's password. Check the MAIL_PASS secret — " + "for Google-hosted boxes it must be a Google App Password; for Hostinger boxes the Hostinger email password." }, 424);
      return J({ error: "Sync failed: " + msg.slice(0, 160) }, 500);
    }
  },
};
