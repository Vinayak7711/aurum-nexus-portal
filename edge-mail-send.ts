// AURUM NEXUS · mail-send — send an email (with attachments) from an ERP mailbox
// via Hostinger SMTP to ANY recipient. The caller's Supabase session identifies
// them; access is checked server-side; the mailbox password lives only in the
// Edge Function vault (secret MAIL_PASS_<KEY>) — never in the browser or database.
// Uses a lean built-in SMTP writer: attachments arrive base64 from the browser and
// are streamed out as-is (no re-encoding), so large files stay within CPU limits.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type",
};
const J = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json", ...CORS } });

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// ---------- tiny SMTP client (implicit TLS, AUTH LOGIN) ----------
class Smtp {
  conn!: Deno.TlsConn; buf = ""; dec = new TextDecoder(); enc = new TextEncoder();
  async connect(host: string, port: number) { this.conn = await Deno.connectTls({ hostname: host, port }); await this.reply(); }
  async fill() { const b = new Uint8Array(16384); const n = await this.conn.read(b); if (n === null) throw new Error("connection closed"); this.buf += this.dec.decode(b.subarray(0, n)); }
  async line(): Promise<string> { while (!this.buf.includes("\r\n")) await this.fill(); const i = this.buf.indexOf("\r\n"); const l = this.buf.slice(0, i); this.buf = this.buf.slice(i + 2); return l; }
  // Read a (possibly multi-line) reply; return {code, text}. Throws on 4xx/5xx unless allow334.
  async reply(allow334 = false): Promise<{ code: number; text: string }> {
    let l = await this.line();
    const code = Number(l.slice(0, 3));
    let text = l;
    while (l.length >= 4 && l[3] === "-") { l = await this.line(); text += "\n" + l; }
    if (code >= 400) throw new Error("SMTP " + text.slice(0, 140));
    if (!allow334 && code === 334) throw new Error("SMTP unexpected auth prompt");
    return { code, text };
  }
  async write(data: Uint8Array) { let off = 0; while (off < data.length) off += await this.conn.write(data.subarray(off)); }
  async cmd(c: string, allow334 = false) { await this.write(this.enc.encode(c + "\r\n")); return await this.reply(allow334); }
  close() { try { this.conn.close(); } catch (_) { /* done */ } }
}

// base64 of a UTF-8 string (small strings: subject, body, headers)
function b64utf8(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 8192) bin += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(bin);
}
// wrap a long base64 string into 76-char lines (cheap: array of slices + join)
function wrap76(b64: string): string {
  if (b64.length <= 76) return b64;
  const out: string[] = [];
  for (let i = 0; i < b64.length; i += 76) out.push(b64.slice(i, i + 76));
  return out.join("\r\n");
}
const rfc2047 = (s: string) => /^[\x20-\x7e]*$/.test(s) ? s : "=?UTF-8?B?" + b64utf8(s) + "?=";
const addrOnly = (s: string) => { const m = s.match(/<([^>]+)>/); return (m ? m[1] : s).trim(); };

export default {
  fetch: async (req: Request) => {
    if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
    try {
      const auth = req.headers.get("authorization") || "";
      const { mailbox, to, cc, bcc, subject, body, attachments } = await req.json().catch(() => ({}));
      if (!mailbox || !to || !subject || !body)
        return J({ error: "mailbox, to, subject and body are all required." }, 400);

      // Attachments — any file type, base64-encoded by the browser. Max 10 files / ~10 MB total.
      const attsIn = Array.isArray(attachments) ? attachments.slice(0, 10) : [];
      const atts: { filename: string; contentType: string; b64: string }[] = [];
      let attBytes = 0;
      for (const a of attsIn) {
        const b64 = String(a?.b64 || "").replace(/[^A-Za-z0-9+/=]/g, "");
        if (!b64) continue;
        attBytes += Math.floor(b64.length * 3 / 4);
        if (attBytes > 10 * 1024 * 1024)
          return J({ error: "Attachments are too large — keep the total under 10 MB." }, 413);
        atts.push({
          filename: String(a?.name || "attachment").replace(/["\r\n]/g, "").slice(0, 180),
          contentType: String(a?.type || "application/octet-stream").replace(/[\r\n]/g, ""),
          b64,
        });
      }

      // Recipients — To / Cc / Bcc, any external address(es), comma-separated.
      const parseList = (v: unknown) => String(v || "").split(/[,;]/).map((s) => s.trim()).filter(Boolean);
      const recipients = parseList(to);
      const ccList = parseList(cc);
      const bccList = parseList(bcc);
      if (recipients.length === 0) return J({ error: "Add at least one recipient." }, 400);
      const bad = [...recipients, ...ccList, ...bccList].find((r) => !EMAIL_RE.test(addrOnly(r)));
      if (bad) return J({ error: "That doesn't look like a valid email address: " + bad }, 400);
      const allEnvelope = [...recipients, ...ccList, ...bccList];   // everyone the server delivers to

      const url = Deno.env.get("SUPABASE_URL")!;
      const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
      const { data: claims } = await createClient(url, anon).auth.getClaims(auth.replace(/^Bearer /i, ""));
      const uid = claims?.claims?.sub;
      if (!uid) return J({ error: "Please sign in first." }, 401);

      const svc = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

      // Mailbox config — match by key OR full address OR address local-part.
      const mbLower = String(mailbox).trim().toLowerCase();
      const { data: boxes, error: boxErr } = await svc.schema("mail").from("mailboxes")
        .select("*").eq("is_active", true);
      if (boxErr) return J({ error: "Mailbox lookup failed: " + boxErr.message }, 500);
      const box = (boxes || []).find((b: Record<string, unknown>) => {
        const k = String(b.key || "").toLowerCase();
        const a = String(b.address || "").toLowerCase();
        return k === mbLower || a === mbLower || a.split("@")[0] === mbLower;
      });
      if (!box)
        return J({ error: "That mailbox is not set up.", available: (boxes || []).map((b: Record<string, unknown>) => b.key) }, 404);

      // Caller must be active and allowed to use this mailbox.
      const { data: me } = await svc.schema("adm").from("users")
        .select("role, is_active, permissions_json").eq("id", uid).maybeSingle();
      if (!me || me.is_active === false) return J({ error: "Your account is not active." }, 403);
      const isDir = me.role === "DIRECTOR";
      const perms = (me.permissions_json || {}) as Record<string, Record<string, boolean>>;
      let allowed = isDir || (box.owner_id != null && box.owner_id === uid);
      if (!allowed && !box.dir_only) {
        if (box.admin_ok && me.role === "ADMIN") allowed = true;
        else if (box.grant_module) allowed = !!(perms?.[box.grant_module]?.[box.grant_action]);
      }
      if (!allowed) return J({ error: "You don't have access to send from this mailbox." }, 403);

      // Mailbox password from the vault (secret MAIL_PASS_<KEY>, punctuation -> underscores, case-insensitive).
      const want = ("MAIL_PASS_" + String(box.key)).replace(/[^a-z0-9_]/gi, "_").toLowerCase();
      const envAll = Deno.env.toObject();
      let pass: string | undefined;
      for (const k in envAll) { if (k.toLowerCase() === want) { pass = envAll[k]; break; } }
      if (pass) pass = pass.trim();   // strip stray spaces / line-breaks from copy-paste
      if (!pass)
        return J({ error: "This mailbox isn't connected yet — its password hasn't been added to the vault." }, 422);

      // ---------- Build the MIME message (attachments pass through untouched) ----------
      const boundary = "AURUM-" + crypto.randomUUID();
      const dateHdr = new Date().toUTCString().replace("GMT", "+0000");
      const fromDisp = rfc2047(String(box.display || "Aurum Spirits"));
      const head =
        "From: " + fromDisp + " <" + box.address + ">\r\n" +
        "To: " + recipients.join(", ") + "\r\n" +
        (ccList.length ? "Cc: " + ccList.join(", ") + "\r\n" : "") +
        "Subject: " + rfc2047(String(subject).slice(0, 500)) + "\r\n" +
        "Date: " + dateHdr + "\r\n" +
        "Message-ID: <" + crypto.randomUUID() + "@" + String(box.address).split("@")[1] + ">\r\n" +
        "MIME-Version: 1.0\r\n";
      const textPart =
        "Content-Type: text/plain; charset=utf-8\r\n" +
        "Content-Transfer-Encoding: base64\r\n\r\n" +
        wrap76(b64utf8(String(body))) + "\r\n";
      let mime: string;
      if (atts.length === 0) {
        mime = head + textPart;
      } else {
        const parts: string[] = [];
        parts.push("--" + boundary + "\r\n" + textPart);
        for (const a of atts) {
          parts.push(
            "--" + boundary + "\r\n" +
            "Content-Type: " + a.contentType + "; name=\"" + a.filename + "\"\r\n" +
            "Content-Disposition: attachment; filename=\"" + a.filename + "\"\r\n" +
            "Content-Transfer-Encoding: base64\r\n\r\n" +
            wrap76(a.b64) + "\r\n",
          );
        }
        mime = head +
          "Content-Type: multipart/mixed; boundary=\"" + boundary + "\"\r\n\r\n" +
          parts.join("") + "--" + boundary + "--\r\n";
      }

      // ---------- Send via Hostinger SMTP (implicit TLS, port 465, AUTH LOGIN) ----------
      const smtp = new Smtp();
      try {
        await smtp.connect((box as { smtp_host?: string }).smtp_host || "smtp.hostinger.com", 465);
        await smtp.cmd("EHLO aurum-nexus");
        await smtp.cmd("AUTH LOGIN", true);
        await smtp.cmd(btoa(String(box.address)), true);
        try { await smtp.cmd(btoa(pass), true); }
        catch (_e) { return J({ error: "The mail server refused this mailbox's password. Check the MAIL_PASS secret value." }, 424); }
        await smtp.cmd("MAIL FROM:<" + box.address + ">");
        // Bcc addresses appear here in the envelope but NOT in the headers above — so they stay blind.
        for (const r of allEnvelope) await smtp.cmd("RCPT TO:<" + addrOnly(r) + ">");
        await smtp.cmd("DATA", true);                    // 354
        await smtp.write(new TextEncoder().encode(mime));
        await smtp.cmd("\r\n.");                          // end of data -> 250
        try { await smtp.cmd("QUIT"); } catch (_) { /* sent already */ }
      } finally { smtp.close(); }

      // Log to the Sent folder (note attachment names in the body).
      const attNote = atts.length ? "\n\n\u{1F4CE} Attachments: " + atts.map((a) => a.filename).join(", ") : "";
      await svc.schema("mail").from("messages").insert({
        mailbox_id: box.id, folder: "SENT",
        from_addr: box.address, to_addr: recipients.join(", "),
        cc_addr: ccList.join(", ") || null, bcc_addr: bccList.join(", ") || null,
        subject: String(subject), body_text: String(body) + attNote,
        sent_at: new Date().toISOString(), is_handled: true, created_by: uid,
      });

      return J({ ok: true, sent_to: allEnvelope.length, attachments: atts.length });
    } catch (e) {
      return J({ error: "Send failed: " + String((e as Error)?.message || e).slice(0, 200) }, 500);
    }
  },
};
