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

/** Sends a one-time code. Returns true on success; never throws. */
export async function sendCode(email, purpose, code) {
  const t = TEMPLATES[purpose];
  if (config.logEmailCodes) console.log(`[mail] ${purpose} code for ${email}: ${code}`);
  try {
    await transport.sendMail({
      from: config.smtp.from,
      to: email,
      subject: t.subject,
      text: `${t.intro}\n\n${code}\n\nThe code expires in ${config.codeTtlMin} minutes. If you did not request it, ignore this email.`,
      html: `<div style="font-family:sans-serif;max-width:480px;margin:auto">
        <h2 style="color:#3949ab">Messenger</h2>
        <p>${t.intro}</p>
        <p style="font-size:32px;letter-spacing:8px;font-weight:bold;background:#eef;padding:16px;text-align:center;border-radius:8px">${code}</p>
        <p style="color:#666">The code expires in ${config.codeTtlMin} minutes. If you did not request it, ignore this email.</p>
      </div>`,
    });
    return true;
  } catch (e) {
    console.error(`[mail] failed to send ${purpose} email: ${e.message}`);
    return false;
  }
}
