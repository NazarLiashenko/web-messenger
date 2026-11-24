import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { query, tx } from '../db.js';
import { decrypt, decryptJson, encrypt, encryptJson, userKey } from '../crypto.js';
import { ApiError, badRequest, forbidden, notFound, parse } from '../errors.js';
import { requireAuth } from '../auth.js';
import { assertMember, getChatMemberIds, getMessage, serializeMessage } from '../services/chats.js';
import { emitToUser } from '../realtime.js';

/*
 * Polls (group chats only).
 *   POST   /api/chats/:id/polls   create {clientId, question, options[2..10], anonymous, multiple}
 *   PUT    /api/polls/:id/vote    vote / change vote {options: [index...]}; [] retracts
 *   DELETE /api/polls/:id/vote    retract my vote
 *   POST   /api/polls/:id/close   stop voting (creator)
 * Realtime: message:new (with the poll) and poll:updated {chatId, messageId, poll}, each member gets
 * their own view (their own choices). Anonymous polls never reveal voters, and the server does not even
 * store voter ids for them, only a blind index that prevents double voting.
 */
export const chatPollsRouter = Router();
export const pollsRouter = Router();
chatPollsRouter.use(requireAuth);
pollsRouter.use(requireAuth);

/** Poll views for messages of type `poll`, from the point of view of `viewerId`. Map messageId -> poll. */
export async function getPollViews(messageIds, viewerId) {
  if (!messageIds.length) return new Map();
  const { rows: polls } = await query('SELECT * FROM polls WHERE message_id = ANY($1::uuid[])', [messageIds]);
  if (!polls.length) return new Map();
  const { rows: votes } = await query('SELECT * FROM poll_votes WHERE poll_id = ANY($1::uuid[]) ORDER BY created_at', [
    polls.map((p) => p.id),
  ]);
  const me = userKey(viewerId);
  const result = new Map();
  for (const p of polls) {
    const texts = decryptJson(p.options_enc);
    const own = votes.filter((v) => v.poll_id === p.id);
    const options = texts.map((text, i) => {
      const forOption = own.filter((v) => v.option_index === i);
      return {
        text,
        votes: forOption.length,
        voterIds: p.anonymous ? null : forOption.map((v) => decrypt(v.voter_enc)),
      };
    });
    result.set(p.message_id, {
      id: p.id,
      anonymous: p.anonymous,
      multiple: p.multiple,
      closed: !!p.closed_at,
      creatorIsMe: p.creator_key === me,
      totalVoters: new Set(own.map((v) => v.voter_key)).size,
      myVotes: own.filter((v) => v.voter_key === me).map((v) => v.option_index),
      options,
    });
  }
  return result;
}

/** Adds `poll` to serialized poll messages (per viewer). */
export async function withPolls(messages, viewerId) {
  const ids = messages.filter((m) => m.type === 'poll' && !m.deletedAt).map((m) => m.id);
  const views = await getPollViews(ids, viewerId);
  return messages.map((m) => (views.has(m.id) ? { ...m, poll: views.get(m.id) } : m));
}

async function emitPollUpdated(pollRow) {
  const memberIds = await getChatMemberIds(pollRow.chat_id);
  await Promise.all(
    memberIds.map(async (uid) => {
      const poll = (await getPollViews([pollRow.message_id], uid)).get(pollRow.message_id);
      emitToUser(uid, 'poll:updated', { chatId: pollRow.chat_id, messageId: pollRow.message_id, poll });
    }),
  );
}

const createSchema = z.object({
  clientId: z.string().min(1).max(64),
  question: z.string().trim().min(1, 'Write a question').max(300, 'Question is too long (max 300)'),
  options: z
    .array(z.string().trim().min(1, 'Options cannot be empty').max(100, 'Option is too long (max 100)'))
    .min(2, 'A poll needs at least 2 options')
    .max(10, 'A poll can have at most 10 options'),
  anonymous: z.boolean().default(true),
  multiple: z.boolean().default(false),
});

chatPollsRouter.post('/:id/polls', async (req, res) => {
  const chatId = req.params.id;
  const memberIds = await assertMember(chatId, req.userId);
  const body = parse(createSchema, req.body);
  const lowered = body.options.map((o) => o.toLowerCase());
  if (new Set(lowered).size !== lowered.length) {
    throw badRequest('VALIDATION_ERROR', 'Options must be different', { field: 'options' });
  }
  const chat = (await query('SELECT kind FROM chats WHERE id=$1', [chatId])).rows[0];
  if (chat.kind !== 'group') throw forbidden('Polls are available in group chats');

  const senderKey = userKey(req.userId);
  const messageId = crypto.randomUUID();
  const created = await tx(async (c) => {
    const ins = await c.query(
      `INSERT INTO messages (id, chat_id, client_id, sender_key, type, body_enc) VALUES ($1,$2,$3,$4,'poll',$5)
       ON CONFLICT (chat_id, sender_key, client_id) DO NOTHING RETURNING id`,
      [messageId, chatId, body.clientId, senderKey, encrypt(body.question)],
    );
    if (!ins.rows.length) return false; // retry of a poll that already exists
    await c.query(
      `INSERT INTO polls (id, message_id, chat_id, creator_key, options_enc, anonymous, multiple)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [crypto.randomUUID(), messageId, chatId, senderKey, encryptJson(body.options), body.anonymous, body.multiple],
    );
    await c.query('UPDATE chats SET last_message_at = now() WHERE id = $1', [chatId]);
    return true;
  });

  let row;
  if (created) row = await getMessage(messageId);
  else {
    const { rows } = await query(`SELECT id FROM messages WHERE chat_id=$1 AND sender_key=$2 AND client_id=$3`, [
      chatId,
      senderKey,
      body.clientId,
    ]);
    row = await getMessage(rows[0].id);
  }
  const base = serializeMessage(row, memberIds);
  if (created) {
    await Promise.all(
      memberIds.map(async (uid) => emitToUser(uid, 'message:new', { message: (await withPolls([base], uid))[0] })),
    );
  }
  const [message] = await withPolls([base], req.userId);
  res.status(created ? 201 : 200).json({ message });
});

async function loadPoll(req) {
  if (!/^[0-9a-f-]{36}$/i.test(req.params.id)) throw notFound('Poll');
  const { rows } = await query(
    `SELECT p.*, m.deleted_at FROM polls p JOIN messages m ON m.id = p.message_id WHERE p.id = $1`,
    [req.params.id],
  );
  const poll = rows[0];
  if (!poll || poll.deleted_at) throw notFound('Poll');
  await assertMember(poll.chat_id, req.userId); // 404 for non-members
  return poll;
}

async function respond(res, poll, userId) {
  await emitPollUpdated(poll);
  res.json({ poll: (await getPollViews([poll.message_id], userId)).get(poll.message_id) });
}

pollsRouter.put('/:id/vote', async (req, res) => {
  const { options } = parse(z.object({ options: z.array(z.number().int().nonnegative()).max(10) }), req.body);
  const poll = await loadPoll(req);
  if (poll.closed_at) throw new ApiError(409, 'POLL_CLOSED', 'This poll is closed');
  const count = decryptJson(poll.options_enc).length;
  const chosen = [...new Set(options)];
  if (chosen.some((i) => i >= count)) throw badRequest('VALIDATION_ERROR', 'Unknown option', { field: 'options' });
  if (!poll.multiple && chosen.length > 1) throw badRequest('VALIDATION_ERROR', 'Only one answer is allowed in this poll');
  const key = userKey(req.userId);
  await tx(async (c) => {
    await c.query('DELETE FROM poll_votes WHERE poll_id=$1 AND voter_key=$2', [poll.id, key]);
    for (const i of chosen) {
      await c.query('INSERT INTO poll_votes (poll_id, voter_key, voter_enc, option_index) VALUES ($1,$2,$3,$4)', [
        poll.id,
        key,
        poll.anonymous ? null : encrypt(req.userId),
        i,
      ]);
    }
  });
  await respond(res, poll, req.userId);
});

pollsRouter.delete('/:id/vote', async (req, res) => {
  const poll = await loadPoll(req);
  if (poll.closed_at) throw new ApiError(409, 'POLL_CLOSED', 'This poll is closed');
  await query('DELETE FROM poll_votes WHERE poll_id=$1 AND voter_key=$2', [poll.id, userKey(req.userId)]);
  await respond(res, poll, req.userId);
});

pollsRouter.post('/:id/close', async (req, res) => {
  const poll = await loadPoll(req);
  if (poll.creator_key !== userKey(req.userId)) throw forbidden('Only the author can close the poll');
  if (!poll.closed_at) await query('UPDATE polls SET closed_at = now() WHERE id=$1', [poll.id]);
  await respond(res, poll, req.userId);
});
