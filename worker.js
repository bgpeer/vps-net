// worker.js —— 青帝：Telegram 机器人（Cloudflare Workers + Workers AI 免费额度）
//
// 机密（只放在 Cloudflare，不进仓库）：TELEGRAM_BOT_TOKEN
// 可选变量：SYSTEM_PROMPT（人设）、AI_MODEL（聊天模型）、SPAM_MODEL（判广告的模型）、WARN_LIMIT（几次警告封，默认 3）
// 绑定：AI（Workers AI）、WARN（KV，记警告次数；GitHub Actions 部署时自动建好绑上，id 不进仓库）
//
// 私聊：每条都用 AI 回答。
// 群里（仓库主人 11/01：「放到群里面当管理」，要这三样）：
//   1. 只在 @青帝、回复青帝的消息、或发 /ask 时才用 AI 回答，平时不插话、不浪费额度
//   2. 非管理员的消息（带链接 / @ / 转发，或者比较长的）让 AI 判是不是广告诈骗，分三档
//      （仓库主人：「可以确定的直接踢，拿不准的才警告吗」）：
//        · 确定是广告 + 这人在群里还没正常说过话（典型广告号：进群第一句就是广告）→ 删掉、直接踢
//        · 确定是广告但这人以前正常聊过（可能号被盗、或者在真心推荐）/ 拿不准 → 删掉 + 警告一次
//        · 不是 → 不动，记下「这人正常说过话」
//      警告满 3 次踢出（「不应该是给予警告，3次吗，然后再封」）；30 天不再犯自动清零。
//      警告提示 60 秒后自己删掉；判错了管理员回复那人的消息发 /unwarn 清掉
//   3. 管理员命令（回复某人的消息再发）：/warn 警告 · /unwarn 清警告 · /ban 踢出 · /mute [10m|2h|1d] 禁言 ·
//      /unmute 解禁 · /del 删消息
// 群里要让它看得到所有消息、能删能禁：把青帝设成群管理员（勾「删除消息」「封禁用户」）。
// 删不掉消息（没给「删除消息」权限）会在群里提醒一行（一小时最多一次）；编辑过的消息也查广告；相册整组删。

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/") return ok();
    if (url.pathname !== "/telegram") return new Response("Not Found", { status: 404 });
    if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

    const update = await request.json().catch(() => null);
    if (!update) return new Response("Bad Request", { status: 400 });

    try {
      const msg = update.message;
      const isGroup = (m) => m && m.chat && (m.chat.type === "group" || m.chat.type === "supergroup");
      if (msg && msg.chat) {
        if (msg.chat.type === "private") await onPrivate(env, msg);
        else if (isGroup(msg)) await onGroup(env, ctx, msg);
      }
      // 群里编辑过的消息：只查广告（先发一句正常话、再改成广告是常见套路），不重新回答、不跑命令
      const ed = update.edited_message;
      if (isGroup(ed)) await onGroupEdited(env, ctx, ed);
    } catch (e) {
      console.log("handle failed:", e?.message || e);
    }
    ctx.waitUntil(sweepNotices(env));              // 顺手删掉到点的提示
    return ok();                                  // 永远回 200：否则 Telegram 会一直重发同一条
  },

  // 每分钟一次（wrangler.toml 的 crons）：群里没人说话时，到点的提示也照样删
  async scheduled(event, env, ctx) {
    ctx.waitUntil(sweepNotices(env));
  },
};

const ok = () => new Response("ok", { status: 200 });

// ==================== 私聊 ====================

async function onPrivate(env, msg) {
  const text = (msg.text || "").trim();
  if (!text) return;
  const cmd = parseCmd(text);
  if (cmd === "/start" || cmd === "/help") {
    return send(env, msg.chat.id, [
      "我在。直接发消息，我会像 AI 一样跟你聊（Cloudflare 免费模型）。",
      "",
      "拉进群并设成管理员后：",
      "· @我、回复我、或 /ask 问题 —— 我才回答",
      "· 自动删广告诈骗，警告 3 次踢出",
      "· 管理员回复某人发 /warn /unwarn /ban /mute /unmute /del",
    ].join("\n"));
  }
  if (cmd === "/ping") return send(env, msg.chat.id, "pong ✅ 我在线");
  if (cmd === "/reset") return send(env, msg.chat.id, "已重置 ✅（当前版本是单轮对话，不保存历史）");
  return send(env, msg.chat.id, await aiAnswer(env, text));
}

// ==================== 群 ====================

async function onGroup(env, ctx, msg) {
  const chatId = msg.chat.id;
  const text = (msg.text || msg.caption || "").trim();
  const me = await getMe(env);
  const cmd = parseCmd(text, me.username);
  const userId = msg.from && msg.from.id;

  // 匿名管理员 / 群自己的频道发的：当管理员看
  const asGroup = msg.sender_chat && (msg.sender_chat.id === chatId || msg.is_automatic_forward);
  const admin = asGroup || (userId && await isAdmin(env, chatId, userId));

  // ---- 管理员命令 ----
  if (ADMIN_CMDS.has(cmd)) {
    if (!admin) return;                           // 普通人发了当没看见
    return adminCommand(env, msg, cmd, text);
  }

  // ---- 问答：@我 / 回复我 / /ask ----
  // @ 的三种样子：@用户名；从成员列表点出来的 @青帝（text_mention，带 id）；手打的「@青帝」纯文字（11/01 真群里就是这样，没回）
  const ents = [...(msg.entities || []), ...(msg.caption_entities || [])];
  const byName = me.first_name ? "@" + me.first_name : "";
  const mentioned =
    (me.username && text.toLowerCase().includes("@" + me.username.toLowerCase())) ||
    ents.some((e) => e.type === "text_mention" && e.user && e.user.id === me.id) ||
    (byName && text.includes(byName));
  const repliedToMe = msg.reply_to_message && msg.reply_to_message.from && msg.reply_to_message.from.id === me.id;
  if (cmd === "/ask" || mentioned || repliedToMe) {
    let q = text;
    if (cmd === "/ask") q = text.replace(/^\/ask(@\w+)?/i, "");
    if (me.username) q = q.replace(new RegExp("@" + me.username, "ig"), "");
    if (byName) q = q.split(byName).join("");
    for (const e of ents) if (e.type === "text_mention" && e.user && e.user.id === me.id) q = q.replace(text.substr(e.offset, e.length), "");
    q = q.trim();
    if (!q) return reply(env, msg, "想问什么？@我 后面直接写问题。");
    return reply(env, msg, await aiAnswer(env, q));
  }

  return spamCheck(env, ctx, msg, msgText(msg), admin);
}

// 查广告要看的文字：正文 / 图片说明 + 引用别处消息时带的那段引文（「回复到别的聊天」常被拿来塞广告）
function msgText(msg) {
  return [msg.text || msg.caption || "", (msg.quote && msg.quote.text) || ""].join("\n").trim();
}

async function onGroupEdited(env, ctx, msg) {
  const chatId = msg.chat.id;
  const userId = msg.from && msg.from.id;
  const asGroup = msg.sender_chat && (msg.sender_chat.id === chatId || msg.is_automatic_forward);
  const admin = asGroup || (userId && await isAdmin(env, chatId, userId));
  return spamCheck(env, ctx, msg, msgText(msg), admin);
}

// 相册（几张图一起发）在 Telegram 里是好几条消息，文字只挂在其中一条上：那条判成广告，同一相册后面到的也一起删
const BAD_ALBUM = new Map();

// 删消息并核对结果。删不掉（11/01 真群里：人踢了、广告还挂着）多半是青帝没有「删除消息」权限 ——
// 群里提醒一行，同一个群一小时最多提醒一次
const DEL_WARNED = new Map();
async function delMsg(env, chatId, messageId) {
  const r = await tg(env, "deleteMessage", { chat_id: chatId, message_id: messageId });
  if (r && r.ok) return true;
  const last = DEL_WARNED.get(chatId) || 0;
  if (Date.now() - last > 3600 * 1000) {
    DEL_WARNED.set(chatId, Date.now());
    await notice(env, chatId, `⚠️ 删不了消息（${(r && r.description) || "未知原因"}）：群设置 → 管理员 → 青帝，打开「删除消息」`, 600);
  }
  return false;
}

// 踢人：revoke_messages 让 Telegram 顺手删掉这人已有的消息；再记 1 小时「刚踢过」，之后才到的消息直接删
const MEM_BANNED = new Map();
const bannedKey = (chatId, userId) => `b:${chatId}:${userId}`;
async function banUser(env, chatId, userId) {
  // 频道身份（id 是负数）用 banChatSenderChat，真人用 banChatMember
  const r = userId < 0
    ? await tg(env, "banChatSenderChat", { chat_id: chatId, sender_chat_id: userId })
    : await tg(env, "banChatMember", { chat_id: chatId, user_id: userId, revoke_messages: true });
  MEM_BANNED.set(bannedKey(chatId, userId), Date.now() + 3600 * 1000);
  if (env.WARN) await env.WARN.put(bannedKey(chatId, userId), "1", { expirationTtl: 3600 });
  return r;
}
async function recentlyBanned(env, chatId, userId) {
  const k = bannedKey(chatId, userId);
  if ((MEM_BANNED.get(k) || 0) > Date.now()) return true;
  return env.WARN ? (await env.WARN.get(k)) !== null : false;
}

// ---- 广告检查：管理员、机器人、群自己的频道不查 ----
// 11/03 真群里：两个号一前一后发同一段广告（后一个是回复前一个），前一个删了踢了，后一个挂着没动。
// 所以：判成广告的那段文字记 1 小时「指纹」，一模一样的再出现不用等 AI，直接按广告处理（AI 那会儿忙不过来也照样拦）；
// 以「频道身份」发的（sender_chat 是别的频道）按频道封（banChatSenderChat），不然封的是 Telegram 的公共占位号。
// 每次判完在 Cloudflare 日志里记一行（不记消息内容），出了问题能查。
const MEM_SPAMFP = new Map();
function spamFp(chatId, text) {
  const t = text.replace(/\s+/g, "").slice(0, 600);
  let h = 2166136261;
  for (let i = 0; i < t.length; i++) h = Math.imul(h ^ t.charCodeAt(i), 16777619);
  return `s:${chatId}:${(h >>> 0).toString(36)}:${t.length}`;
}
async function isKnownSpam(env, fp) {
  if ((MEM_SPAMFP.get(fp) || 0) > Date.now()) return true;
  return env.WARN ? (await env.WARN.get(fp)) !== null : false;
}
async function markSpam(env, fp) {
  MEM_SPAMFP.set(fp, Date.now() + 3600 * 1000);
  if (env.WARN) await env.WARN.put(fp, "1", { expirationTtl: 3600 });
}

async function spamCheck(env, ctx, msg, text, admin) {
  const chatId = msg.chat.id;
  const ch = msg.sender_chat && msg.sender_chat.id !== chatId && !msg.is_automatic_forward ? msg.sender_chat : null;
  const who = ch ? { id: ch.id, first_name: ch.title || "频道" } : msg.from;   // 用频道身份发的：按频道算
  const userId = who && who.id;
  if (admin || !userId || (!ch && msg.from && msg.from.is_bot)) return;

  const album = msg.media_group_id;
  const now = Date.now();
  for (const [k, t] of BAD_ALBUM) if (t < now) BAD_ALBUM.delete(k);
  for (const [k, t] of MEM_SPAMFP) if (t < now) MEM_SPAMFP.delete(k);
  if (album && BAD_ALBUM.has(album)) return delMsg(env, chatId, msg.message_id);
  // 刚被踢的人后面还到的消息（长广告被 Telegram 拆成好几条、同时发的几条，踢之前已经发出去了）：不用再判，直接删
  if (await recentlyBanned(env, chatId, userId)) return delMsg(env, chatId, msg.message_id);

  if (!worthChecking(msg, text)) return;
  const fp = spamFp(chatId, text);
  let verdict = (await isKnownSpam(env, fp)) ? "SURE" : await spamVerdict(env, text);
  console.log("spam-check", JSON.stringify({ chat: chatId, user: userId, len: text.length, verdict, asChannel: !!ch }));
  if (verdict === "ERR") return;                 // AI 判不了：这次放过，但不记「正常说过话」
  if (verdict === "OK") {
    await markKnown(env, chatId, userId);
    return;
  }
  if (verdict === "SURE") await markSpam(env, fp);

  if (album) BAD_ALBUM.set(album, now + 120 * 1000);
  await delMsg(env, chatId, msg.message_id);
  if (verdict === "SURE" && (ch || !(await isKnown(env, chatId, userId)))) {
    await banUser(env, chatId, userId);
    await setWarns(env, chatId, userId, 0);
    return notice(env, chatId, `⛔ 已踢出 ${nameOf(who)}（明显广告）`);
  }
  await warn(env, chatId, who, verdict === "SURE" ? "广告已删除" : "疑似广告已删除");
}

// ==================== 警告：满 WARN_LIMIT 次踢出 ====================
// 次数记在 KV（env.WARN），30 天没再犯自动过期清零。没绑 KV 时退回内存（Worker 实例换了会丢，只是兜底）。

const WARN_TTL = 30 * 86400;
const MEM_WARN = new Map();
const warnLimit = (env) => Math.max(1, parseInt(env.WARN_LIMIT || "3", 10) || 3);
const warnKey = (chatId, userId) => `w:${chatId}:${userId}`;

async function getWarns(env, chatId, userId) {
  const k = warnKey(chatId, userId);
  if (env.WARN) return parseInt((await env.WARN.get(k)) || "0", 10) || 0;
  return MEM_WARN.get(k) || 0;
}

async function setWarns(env, chatId, userId, n) {
  const k = warnKey(chatId, userId);
  if (env.WARN) {
    if (n > 0) await env.WARN.put(k, String(n), { expirationTtl: WARN_TTL });
    else await env.WARN.delete(k);
  } else if (n > 0) MEM_WARN.set(k, n);
  else MEM_WARN.delete(k);
}

// 警告一次；到上限就踢出并清零。返回发出的那条提示（banned=true 表示这次踢了）
async function warn(env, chatId, user, why) {
  const limit = warnLimit(env);
  const n = (await getWarns(env, chatId, user.id)) + 1;
  if (n >= limit) {
    await banUser(env, chatId, user.id);
    await setWarns(env, chatId, user.id, 0);
    const r = await notice(env, chatId, `⛔ ${nameOf(user)} 警告满 ${limit} 次，已踢出`);
    return { ...(r || {}), banned: true };
  }
  await setWarns(env, chatId, user.id, n);
  return notice(env, chatId, `⚠️ ${nameOf(user)}：${why}，警告 ${n}/${limit}（满 ${limit} 次踢出）`);
}

// 「这人在群里正常说过话」：AI 判过 OK 的消息记一次（每人只写一次 KV），90 天不说话过期
const KNOWN_TTL = 90 * 86400;
const MEM_KNOWN = new Set();
const knownKey = (chatId, userId) => `k:${chatId}:${userId}`;

async function isKnown(env, chatId, userId) {
  const k = knownKey(chatId, userId);
  if (env.WARN) return (await env.WARN.get(k)) !== null;
  return MEM_KNOWN.has(k);
}

async function markKnown(env, chatId, userId) {
  const k = knownKey(chatId, userId);
  if (env.WARN) {
    if ((await env.WARN.get(k)) === null) await env.WARN.put(k, "1", { expirationTtl: KNOWN_TTL });
  } else MEM_KNOWN.add(k);
}

const ADMIN_CMDS = new Set(["/warn", "/unwarn", "/ban", "/mute", "/unmute", "/del"]);

async function adminCommand(env, msg, cmd, text) {
  const chatId = msg.chat.id;
  const target = msg.reply_to_message;
  // 命令本身删掉，群里干净
  await tg(env, "deleteMessage", { chat_id: chatId, message_id: msg.message_id });
  if (!target) return notice(env, chatId, `用法：回复要处理的那条消息，再发 ${cmd}`);

  const who = target.from;
  if (cmd === "/del") {
    return tg(env, "deleteMessage", { chat_id: chatId, message_id: target.message_id });
  }
  if (!who || who.is_bot && who.id === (await getMe(env)).id) return;
  if (await isAdmin(env, chatId, who.id)) return notice(env, chatId, "管理员不能处理。");

  if (cmd === "/warn") {
    await tg(env, "deleteMessage", { chat_id: chatId, message_id: target.message_id });
    return warn(env, chatId, who, "管理员警告");
  }
  if (cmd === "/unwarn") {
    await setWarns(env, chatId, who.id, 0);
    return notice(env, chatId, `✅ 已清掉 ${nameOf(who)} 的警告`);
  }
  if (cmd === "/ban") {
    await tg(env, "deleteMessage", { chat_id: chatId, message_id: target.message_id });
    await banUser(env, chatId, who.id);
    return notice(env, chatId, `⛔ 已踢出 ${nameOf(who)}`);
  }
  if (cmd === "/mute") {
    const secs = parseDuration(text.split(/\s+/)[1]);
    const body = { chat_id: chatId, user_id: who.id, permissions: NO_PERMS };
    if (secs) body.until_date = Math.floor(Date.now() / 1000) + secs;
    await tg(env, "restrictChatMember", body);
    return notice(env, chatId, `🔇 已禁言 ${nameOf(who)}${secs ? "（" + text.split(/\s+/)[1] + "）" : "（直到解禁）"}`);
  }
  if (cmd === "/unmute") {
    await tg(env, "restrictChatMember", { chat_id: chatId, user_id: who.id, permissions: ALL_PERMS });
    return notice(env, chatId, `🔊 已解除 ${nameOf(who)} 的禁言`);
  }
}

const NO_PERMS = {
  can_send_messages: false, can_send_audios: false, can_send_documents: false, can_send_photos: false,
  can_send_videos: false, can_send_video_notes: false, can_send_voice_notes: false, can_send_polls: false,
  can_send_other_messages: false, can_add_web_page_previews: false,
};
const ALL_PERMS = Object.fromEntries(Object.keys(NO_PERMS).map((k) => [k, true]));

// 10m / 2h / 1d → 秒；不认识返回 0（= 一直禁到解禁）。Telegram 少于 30 秒或超过 366 天都当永久。
function parseDuration(s) {
  const m = /^(\d+)\s*([mhd])$/i.exec(String(s || ""));
  if (!m) return 0;
  return Number(m[1]) * { m: 60, h: 3600, d: 86400 }[m[2].toLowerCase()];
}

// 只查「像广告」的：带链接 / @ / 转发 / 按钮，或者 15 字以上。几个字的闲聊不查，省额度。
function worthChecking(msg, text) {
  if (!text) return false;
  const ents = [...(msg.entities || []), ...(msg.caption_entities || [])];
  if (ents.some((e) => ["url", "text_link", "mention", "text_mention"].includes(e.type))) return true;
  if (msg.forward_origin || msg.forward_from || msg.forward_from_chat || msg.reply_markup) return true;
  if (/t\.me\/|https?:\/\//i.test(text)) return true;
  return text.length >= 15;
}

function nameOf(u) {
  if (!u) return "TA";
  const n = [u.first_name, u.last_name].filter(Boolean).join(" ");
  return n || (u.username ? "@" + u.username : "TA");
}

// ==================== 群里的提示：过一会儿自己删掉 ====================
// 仓库主人：「让青帝把这些人踢出的信息删掉之后把自己的信息也删掉」。踢人 / 警告 / 管理员命令的回执都走 notice()，
// 默认 60 秒后删（「删不了消息」那条留 10 分钟，给管理员看见）。AI 问答的回答不删。
// 不能靠 waitUntil 里 sleep：Cloudflare 只给响应后 30 秒，以前写的 60 秒其实删不掉。
// 所以记进 KV 的待删清单（一个键 pending），每次有消息进来和每分钟的 cron 各扫一遍；没绑 KV 就记内存。
const MEM_PENDING = [];

async function notice(env, chatId, text, secs = 60) {
  const r = await send(env, chatId, text);
  const mid = r && r.ok && r.result && r.result.message_id;
  if (mid) await queueDelete(env, chatId, mid, secs);
  return r;
}

async function queueDelete(env, chatId, messageId, secs) {
  const item = { c: chatId, m: messageId, t: Date.now() + secs * 1000 };
  if (!env.WARN) { MEM_PENDING.push(item); return; }
  const list = JSON.parse((await env.WARN.get("pending")) || "[]");
  list.push(item);
  await env.WARN.put("pending", JSON.stringify(list.slice(-200)));
}

async function sweepNotices(env) {
  try {
    const now = Date.now();
    const list = env.WARN ? JSON.parse((await env.WARN.get("pending")) || "[]") : MEM_PENDING.splice(0);
    if (!list.length) return;
    const keep = [];
    for (const it of list) {
      if (it.t > now) { keep.push(it); continue; }
      await tg(env, "deleteMessage", { chat_id: it.c, message_id: it.m });   // 删不掉（已被手动删）也算处理过
    }
    if (env.WARN) {
      if (keep.length !== list.length) {
        if (keep.length) await env.WARN.put("pending", JSON.stringify(keep));
        else await env.WARN.delete("pending");
      }
    } else MEM_PENDING.push(...keep);
  } catch (e) {
    console.log("sweep failed:", e?.message || e);
  }
}

// ==================== Telegram ====================

async function tg(env, method, body) {
  const token = env.TELEGRAM_BOT_TOKEN;
  if (!token) { console.log("缺少 TELEGRAM_BOT_TOKEN"); return null; }
  const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok || !data || !data.ok) console.log("tg failed:", method, res.status, data && data.description);
  return data;
}

function send(env, chatId, text) {
  return tg(env, "sendMessage", {
    chat_id: chatId,
    text: String(text || "（我收到了，但没生成出可读文本）").slice(0, 3800),
    disable_web_page_preview: true,
  });
}

function reply(env, msg, text) {
  return tg(env, "sendMessage", {
    chat_id: msg.chat.id,
    text: String(text || "（我收到了，但没生成出可读文本）").slice(0, 3800),
    disable_web_page_preview: true,
    reply_parameters: { message_id: msg.message_id, allow_sending_without_reply: true },
  });
}

// "/mute@qingdibot 1h" → "/mute"；别的机器人的命令（@别人）返回 ""
function parseCmd(text, myName) {
  const m = /^\/([a-z]+)(?:@(\w+))?/i.exec(text || "");
  if (!m) return "";
  if (m[2] && myName && m[2].toLowerCase() !== myName.toLowerCase()) return "";
  return "/" + m[1].toLowerCase();
}

// 同一个 Worker 实例里缓存：机器人自己是谁、谁是管理员（5 分钟）
let ME = null;
async function getMe(env) {
  if (ME) return ME;
  const d = await tg(env, "getMe", {});
  if (d && d.ok) ME = d.result;
  return ME || { id: 0, username: "" };
}

const ADMIN_CACHE = new Map();
async function isAdmin(env, chatId, userId) {
  const key = chatId + ":" + userId;
  const hit = ADMIN_CACHE.get(key);
  if (hit && hit.t > Date.now()) return hit.v;
  const d = await tg(env, "getChatMember", { chat_id: chatId, user_id: userId });
  const v = !!(d && d.ok && ["creator", "administrator"].includes(d.result.status));
  ADMIN_CACHE.set(key, { v, t: Date.now() + 5 * 60 * 1000 });
  return v;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ==================== Workers AI ====================
//
// 以前「不智能」：8B 小模型 + 拼字符串的 prompt（"用户：…\n助手："），小模型顺着自问自答编下去。
// 现在用 messages（走模型自己的对话模板），默认 Qwen3 30B，出错退回 Llama 3.3 70B；AI_MODEL 可覆盖。

const MODELS = [
  "@cf/qwen/qwen3-30b-a3b-fp8",
  "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
];

async function aiAnswer(env, userText) {
  try {
    return await callWorkersAI(env, userText);
  } catch (e) {
    return `出错了：${e?.message || e}`;
  }
}

async function callWorkersAI(env, userText) {
  if (!env.AI) throw new Error('Workers AI 未绑定：wrangler.toml 里要有 [ai] binding="AI"');
  const system =
    env.SYSTEM_PROMPT ||
    "你是一个中文聊天助手。回答要简洁、直接、实用。不要胡编；不确定就说明不确定。只回答用户这一句，不要替用户续写对话。";
  const messages = [
    { role: "system", content: system },
    { role: "user", content: userText },
  ];
  const models = env.AI_MODEL ? [env.AI_MODEL, ...MODELS] : MODELS;
  let lastErr = null;
  for (const model of models) {
    try {
      const text = cleanReply(pickText(await env.AI.run(model, { messages, max_tokens: 1024 })));
      if (text) return text;
    } catch (e) {
      lastErr = e;
      console.log("AI model failed:", model, e?.message || e);
    }
  }
  if (lastErr) throw lastErr;
  return "";
}

// 判广告：分 SURE（确定）/ MAYBE（拿不准）/ OK 三档。要分「确定」就不能用太小的模型（8B 分不清程度），
// 默认 Llama 3.3 70B：只回一个词，输入几百字，免费额度一天够判上千条。SPAM_MODEL 可覆盖。
// 回的不是这三个词当 OK，宁可漏不错杀；大模型出错（限流 / 不可用）退 8B 再判一次，还不行返回 ERR（这次放过）。
const SPAM_MODEL = "@cf/meta/llama-3.3-70b-instruct-fp8-fast";
const SPAM_FALLBACK = "@cf/meta/llama-3.1-8b-instruct-fast";

async function spamVerdict(env, text) {
  if (!env.AI) return "ERR";
  for (const model of [env.SPAM_MODEL || SPAM_MODEL, SPAM_FALLBACK]) {
    const v = await spamVerdictWith(env, model, text);
    if (v !== "ERR") return v;
  }
  return "ERR";
}

async function spamVerdictWith(env, model, text) {
  try {
    const r = await env.AI.run(model, {
      messages: [
        {
          role: "system",
          content: [
            "你是 Telegram 技术交流群的反垃圾审核。判断用户这条消息，只回答一个词：SURE、MAYBE 或 OK。",
            "SURE = 明显的广告诈骗，不会是正常群友说的话：留微信 / QQ / TG 号或链接拉人私聊、",
            "推广别的群或频道、博彩、色情、刷单兼职、卖号卖卡、代充、高收益投资、「私聊领福利」这类。",
            "MAYBE = 有推广嫌疑，但也可能是群友正常分享：比如推荐某个机场 / 软件 / 服务并附了链接或邀请码。",
            "OK = 正常聊天、提问、讨论技术、分享经验、发教程或项目链接。",
            "拿不准是 SURE 还是 MAYBE 时回 MAYBE；拿不准是 MAYBE 还是 OK 时回 OK。",
          ].join("\n"),
        },
        { role: "user", content: text.slice(0, 1500) },
      ],
      max_tokens: 5,
    });
    const v = cleanReply(pickText(r)).toUpperCase();
    if (/\bSURE\b/.test(v)) return "SURE";
    if (/\bMAYBE\b/.test(v)) return "MAYBE";
    return "OK";
  } catch (e) {
    console.log("spam check failed:", model, e?.message || e);
    return "ERR";
  }
}

// 不同模型返回的格式不一样：{ response } 或 OpenAI 风格的 { choices: [{ message: { content } }] }
function pickText(result) {
  if (!result) return "";
  if (typeof result === "string") return result;
  if (typeof result.response === "string") return result.response;
  const c = result.choices && result.choices[0];
  if (c && c.message && typeof c.message.content === "string") return c.message.content;
  return "";
}

// Qwen3 会先输出 <think>…</think> 思考过程，只留答案；万一还是续写了「用户：」就截掉
function cleanReply(text) {
  let t = String(text || "").replace(/<think>[\s\S]*?<\/think>/g, "").replace(/^[\s\S]*<\/think>/, "");
  const cut = t.search(/\n\s*(用户|User)\s*[:：]/);
  if (cut > 0) t = t.slice(0, cut);
  return t.trim();
}
