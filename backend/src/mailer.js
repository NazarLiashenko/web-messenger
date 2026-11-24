import nodemailer from 'nodemailer';
import { config } from './config.js';

const transport = nodemailer.createTransport({
  host: config.smtp.host,
  port: config.smtp.port,
  secure: config.smtp.secure,
  auth: config.smtp.user ? { user: config.smtp.user, pass: config.smtp.pass } : undefined,
});

const TEMPLATES = {
  verify_email: {
    subject: 'Confirm your email',
    intro: 'Welcome to Messenger! Use this code to confirm your email address:',
  },
  change_email: {
    subject: 'Confirm your new email',
    intro: 'Use this code to confirm your new email address:',
  },
  reset_password: {
    subject: 'Reset your password',
    intro: 'Someone (hopefully you) asked to reset your Messenger password. Use this code:',
  },
};

/**
 * Brevo transactional email over HTTPS. Used when BREVO_API_KEY is set: many hosts (Render's free
 * tier among them) block outbound SMTP, while HTTP APIs still work. MAIL_FROM must be a sender
 * verified in Brevo, e.g. "Messenger <you@gmail.com>".
 */
async function sendViaBrevo(to, subject, textContent, htmlContent) {
  const m = /^\s*(.*?)\s*<([^>]+)>\s*$/.exec(config.smtp.from);
  const sender = m ? { name: m[1] || 'Messenger', email: m[2] } : { name: 'Messenger', email: config.smtp.from.trim() };
  const res = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: { 'api-key': config.brevoApiKey, 'content-type': 'application/json', accept: 'application/json' },
    body: JSON.stringify({ sender, to: [{ email: to }], subject, textContent, htmlContent }),
  });
  if (!res.ok) throw new Error(`Brevo ${res.status}: ${(await res.text()).slice(0, 200)}`);
}

/** Sends a one-time code (Brevo API if configured, SMTP otherwise). Returns true on success; never throws. */
export async function sendCode(email, purpose, code) {
  const t = TEMPLATES[purpose];
  if (config.logEmailCodes) console.log(`[mail] ${purpose} code for ${email}: ${code}`);
  const expiry = `The code expires in ${config.codeTtlMin} minutes. If you did not request it, ignore this email.`;
  const text = `${t.intro}\n\n${code}\n\n${expiry}`;
  const html = `<div style="font-family:sans-serif;max-width:480px;margin:auto">
        <h2 style="color:#3949ab">Messenger</h2>
        <p>${t.intro}</p>
        <p style="font-size:32px;letter-spacing:8px;font-weight:bold;background:#eef;padding:16px;text-align:center;border-radius:8px">${code}</p>
        <p style="color:#666">${expiry}</p>
      </div>`;
  try {
    if (config.brevoApiKey) await sendViaBrevo(email, t.subject, text, html);
    else await transport.sendMail({ from: config.smtp.from, to: email, subject: t.subject, text, html });
    return true;
  } catch (e) {
    console.error(`[mail] failed to send ${purpose} email: ${e.message}`);
    return false;
  }
}
