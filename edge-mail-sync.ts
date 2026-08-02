// AURUM NEXUS · mail-sync — pulls new mail for one department box via Gmail POP3S.
// Auth: caller's Supabase session token; access re-checked against mail.mailboxes RLS.
// Password comes from the secret MAIL_PASS_<KEY>; it never leaves this function.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, apikey, content-type" };
const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json", ...CORS } });

class Pop {
  conn!: Deno.TlsConn; buf = ""; dec = new TextDecoder(); enc = new TextEncoder();
  async connect() { this.conn = await Deno.connectTls({ hostname: "pop.gmail.com", port: 995 }); await this.line(); }
  async fill() { const b = new Uint8Array(16384); const n = await this.conn.read(b); if (n === null) throw new Error("closed"); this.buf += this.dec.decode(b.subarray(0, n)); }
  async line(): Promise<string> { while (!this.buf.includes("\r\n")) await this.fill(); const i = this.buf.indexOf("\r\n"); const l = this.buf.slice(0, i); this.buf = this.buf.slice(i + 2); return l; }
  async cmd(c: string): Promise<string> { await this.conn.write(this.enc.encode(c + "\r\n")); const l = await this.line(); if (!l.startsWith("+OK")) throw new Error(c.split(" ")[0] + " failed: " + l.slice(0, 80)); return l; }
  async multi(): Promise<string[]> { const out: string[] = []; while (true) { const l = await this.line(); if (l === ".") break; out.push(l.startsWith("..") ? l.slice(1) : l); } return out; }
  close() { try { this.conn.close(); } catch (_) { /* done */ } }
}

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
function parseMail(raw: string) {
  const cut = raw.indexOf("\r\n\r\n");
  const head = (cut >= 0 ? raw.slice(0, cut) : raw).replace(/\r\n[ \t]+/g, " ");
  let body = cut >= 0 ? raw.slice(cut + 4) : "";
  const h = (n: string) => { const m = head.match(new RegExp("^" + n + ":[ \t]*(.*)$", "im")); return m ? decWord(m[1].trim()) : null; };
  const ctype = h("Content-Type") || "text/plain";
  const bMatch = ctype.match(/boundary="?([^";]+)"?/i);
  if (bMatch) {
    // multipart: take the first text/plain part
    const parts = body.split("--" + bMatch[1]);
    let best = "";
    for (const p of parts) {
      const pc = p.indexOf("\r\n\r\n"); if (pc < 0) continue;
      const ph = p.slice(0, pc).toLowerCase();
      if (ph.includes("text/plain")) { best = p.slice(pc + 4); if (ph.includes("base64")) { try { best = new TextDecoder().decode(Uint8Array.from(atob(best.replace(/\s/g, "")), c => c.charCodeAt(0))); } catch (_) { /* keep */ } } else if (ph.includes("quoted-printable")) best = decQP(best); break; }
    }
    body = best || "(no plain-text part — open in Gmail for the full message)";
  } else {
    const cte = (h("Content-Transfer-Encoding") || "").toLowerCase();
    if (cte.includes("base64")) { try { body = new TextDecoder().decode(Uint8Array.from(atob(body.replace(/\s/g, "")), c => c.charCodeAt(0))); } catch (_) { /* keep */ } }
    else if (cte.includes("quoted-printable")) body = decQP(body);
  }
  return { from: h("From"), to: h("To"), subject: h("Subject"), date: h("Date"), msgId: h("Message-ID"), body: body.slice(0, 20000) };
}

export default {
  fetch: async (req: Request) => {
    if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
    try {
      const auth = req.headers.get("authorization") || "";
      const { mailbox } = await req.json().catch(() => ({}));
      if (!mailbox) return J({ error: "Which mailbox?" }, 400);
      const url = Deno.env.get("SUPABASE_URL")!;
      const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { authorization: auth } } });
      const { data: userData } = await userClient.auth.getUser(auth.replace(/^Bearer /i, ""));
      if (!userData?.user) return J({ error: "Sign in first." }, 401);
      // RLS answers the access question: the row is only visible if this user may open the box.
      const { data: box } = await userClient.schema("mail").from("mailboxes").select("*").eq("key", mailbox).maybeSingle();
      if (!box) return J({ error: "You do not have access to this mailbox." }, 403);
      const pass = Deno.env.get("MAIL_PASS_" + String(mailbox).toUpperCase());
      if (!pass) return J({ error: "This mailbox is not connected yet — its app password has not been set in Supabase secrets (MAIL_PASS_" + String(mailbox).toUpperCase() + ")." }, 424);

      const svc = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
      const { data: known } = await svc.schema("mail").from("messages").select("pop_uidl").eq("mailbox_id", box.id).eq("folder", "IN").not("pop_uidl", "is", null);
      const seen = new Set((known || []).map((r: { pop_uidl: string }) => r.pop_uidl));

      const pop = new Pop();
      let fetched = 0, listed = 0;
      try {
        await pop.connect();
        await pop.cmd("USER recent:" + box.address);
        await pop.cmd("PASS " + pass);
        await pop.cmd("UIDL");
        const uidls = (await pop.multi()).map(l => { const [n, u] = l.split(" "); return { n: Number(n), u }; });
        listed = uidls.length;
        const fresh = uidls.filter(x => x.u && !seen.has(x.u)).slice(-30);   // newest 30 per run
        for (const m of fresh) {
          await pop.cmd("RETR " + m.n);
          const raw = (await pop.multi()).join("\r\n");
          const p = parseMail(raw);
          const { error } = await svc.schema("mail").from("messages").insert({
            mailbox_id: box.id, folder: "IN", pop_uidl: m.u, msg_id: p.msgId,
            from_addr: p.from, to_addr: p.to, subject: p.subject || "(no subject)",
            sent_at: p.date ? new Date(p.date).toISOString() : null, body_text: p.body,
          });
          if (!error) fetched++;
        }
        await pop.cmd("QUIT");
      } finally { pop.close(); }
      return J({ ok: true, mailbox, on_server: listed, new_messages: fetched });
    } catch (e) {
      const msg = (e as Error).message || String(e);
      if (/PASS failed/i.test(msg)) return J({ error: "Gmail refused the password for this mailbox. Check the app password secret, and that POP is enabled in that Gmail account." }, 424);
      return J({ error: "Sync failed: " + msg.slice(0, 160) }, 500);
    }
  },
};
