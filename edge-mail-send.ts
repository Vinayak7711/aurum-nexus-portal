// AURUM NEXUS · mail-send — sends mail from a department box via Gmail SMTPS.
// Auth: caller's Supabase session token; access re-checked via mailbox RLS.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, apikey, content-type" };
const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json", ...CORS } });
const b64 = (s: string) => btoa(String.fromCharCode(...new TextEncoder().encode(s)));

class Smtp {
  conn!: Deno.TlsConn; buf = ""; dec = new TextDecoder(); enc = new TextEncoder();
  async connect() { this.conn = await Deno.connectTls({ hostname: "smtp.gmail.com", port: 465 }); await this.expect("220"); }
  async fill() { const b = new Uint8Array(8192); const n = await this.conn.read(b); if (n === null) throw new Error("closed"); this.buf += this.dec.decode(b.subarray(0, n)); }
  async reply(): Promise<string> {
    while (true) {
      const lines = this.buf.split("\r\n").filter(l => l);
      const last = lines[lines.length - 1];
      if (last && /^\d{3} /.test(last)) { const r = this.buf; this.buf = ""; return r; }
      await this.fill();
    }
  }
  async expect(code: string, what = ""): Promise<string> { const r = await this.reply(); if (!r.trimStart().startsWith(code) && !r.split("\r\n").some(l => l.startsWith(code))) throw new Error((what || "SMTP") + " failed: " + r.slice(0, 100)); return r; }
  async cmd(c: string, code: string, what = ""): Promise<string> { await this.conn.write(this.enc.encode(c + "\r\n")); return await this.expect(code, what || c.split(" ")[0]); }
  close() { try { this.conn.close(); } catch (_) { /* done */ } }
}

export default {
  fetch: async (req: Request) => {
    if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
    try {
      const auth = req.headers.get("authorization") || "";
      const { mailbox, to, subject, body } = await req.json().catch(() => ({}));
      if (!mailbox || !to || !subject || !body) return J({ error: "mailbox, to, subject and body are all needed." }, 400);
      const rcpts = String(to).split(/[,;]/).map((s: string) => s.trim()).filter(Boolean);
      if (!rcpts.length || rcpts.some((r: string) => !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(r))) return J({ error: "Check the To address(es)." }, 400);
      const url = Deno.env.get("SUPABASE_URL")!;
      const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
      const { data: claims } = await createClient(url, anon).auth.getClaims(auth.replace(/^Bearer /i, ""));
      const uid = claims?.claims?.sub;
      if (!uid) return J({ error: "Sign in first." }, 401);
      const userClient = createClient(url, anon, { global: { headers: { authorization: auth } } });
      const { data: box } = await userClient.schema("mail").from("mailboxes").select("*").eq("key", mailbox).maybeSingle();
      if (!box) return J({ error: "You do not have access to this mailbox." }, 403);
      const pass = Deno.env.get("MAIL_PASS_" + String(mailbox).toUpperCase());
      if (!pass) return J({ error: "This mailbox is not connected yet — its app password has not been set in Supabase secrets." }, 424);

      const s = new Smtp();
      try {
        await s.connect();
        await s.cmd("EHLO aurumspirits.com", "250");
        await s.cmd("AUTH LOGIN", "334");
        await s.cmd(b64(box.address), "334", "username");
        await s.cmd(b64(pass), "235", "Gmail sign-in (check the app password secret)");
        await s.cmd("MAIL FROM:<" + box.address + ">", "250");
        for (const r of rcpts) await s.cmd("RCPT TO:<" + r + ">", "250", "recipient " + r);
        await s.cmd("DATA", "354");
        const now = new Date();
        const msg = [
          "From: " + box.display + " — Aurum Spirits <" + box.address + ">",
          "To: " + rcpts.join(", "),
          "Subject: " + String(subject).replace(/[\r\n]/g, " "),
          "Date: " + now.toUTCString(),
          "MIME-Version: 1.0",
          "Content-Type: text/plain; charset=utf-8",
          "Content-Transfer-Encoding: 8bit",
          "",
          String(body).replace(/\r?\n/g, "\r\n").replace(/^\./gm, ".."),
        ].join("\r\n");
        await s.conn.write(new TextEncoder().encode(msg + "\r\n.\r\n"));
        await s.expect("250", "send");
        await s.cmd("QUIT", "221").catch(() => {});
      } finally { s.close(); }

      const svc = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
      await svc.schema("mail").from("messages").insert({
        mailbox_id: box.id, folder: "SENT", from_addr: box.address, to_addr: rcpts.join(", "),
        subject, sent_at: new Date().toISOString(), body_text: String(body).slice(0, 20000),
        created_by: uid, is_handled: true,
      });
      return J({ ok: true, sent_to: rcpts });
    } catch (e) {
      return J({ error: "Send failed: " + ((e as Error).message || String(e)).slice(0, 160) }, 500);
    }
  },
};
