// worker.js —— 青帝：Telegram 机器人（Cloudflare Workers + Workers AI 免费额度）
//
// 机密（只放在 Cloudflare，不进仓库）：TELEGRAM_BOT_TOKEN
// 可选变量：SYSTEM_PROMPT（人设）、AI_MODEL（聊天模型）、SPAM_MODEL（判广告的模型）、WARN_LIMIT（几次警告封，默认 3）
// 绑定：AI（Workers AI）、WARN（KV，记警告次数；GitHub Actions 部署时自动建好绑上，id 不进仓库）
//
// 私聊：每条都用 AI 回答。
// 群里（仓库主人 11/01：「放到群里面当管理」，要这三样）：
//   1. 只在 @青帝、回复青帝的消息、或发 /ask 时才用 AI 回答，平时不插话、不浪费额度
//   2. 非管理员的消息（带链接 / @ / 转发，或者比较长的）让 AI 判是不是广告诈骗：是 → 删掉 + 警告一次，
//      满 3 次踢出（仓库主人：「不应该是给予警告，3次吗，然后再封」）。警告 30 天不再犯自动清零。
//      警告提示 60 秒后自己删掉；判错了管理员回复那人的消息发 /unwarn 清掉
//   3. 管理员命令（回复某人的消息再发）：/warn 警告 · /unwarn 清警告 · /ban 踢出 · /mute [10m|2h|1d] 禁言 ·
//      /unmute 解禁 · /del 删消息
// 群里要让它看得到所有消息、能删能禁：把青帝设成群管理员（勾「删除消息」「封禁用户」）。

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/") return ok();
    if (url.pathname !== "/telegram") return new Response("Not Found", { status: 404 });
    if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

    const update = await request.json().catch(() => null);
    if (!update) return new Response("Bad Request", { status: 400 });

    try {
      const msg = update.message;                 // 群里不处理「编辑过的消息」，免得改一个字又触发一次
      if (msg && msg.chat) {
        if (msg.chat.type === "private") await onPrivate(env, msg);
        else if (msg.chat.type === "group" || msg.chat.type === "supergroup") await onGroup(env, ctx, msg);
      }
    } catch (e) {
      console.log("handle failed:", e?.message || e);
    }
    return ok();                                  // 永远回 200：否则 Telegram 会一直重发同一条
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

  // ---- 广告检查：管理员、机器人、群自己的频道不查 ----
  if (admin || !userId || (msg.from && msg.from.is_bot)) return;
  if (!worthChecking(msg, text)) return;
  if (!(await isSpam(env, text))) return;

  await tg(env, "deleteMessage", { chat_id: chatId, message_id: msg.message_id });
  const note = await warn(env, chatId, msg.from, "疑似广告已删除");
  // 警告提示 60 秒后自己删掉，群里不留一堆（踢人的那条留着）
  const nid = note && !note.banned && note.result && note.result.message_id;
  if (nid) ctx.waitUntil(sleep(60000).then(() => tg(env, "deleteMessage", { chat_id: chatId, message_id: nid })));
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
    await tg(env, "banChatMember", { chat_id: chatId, user_id: user.id, revoke_messages: true });
    await setWarns(env, chatId, user.id, 0);
    const r = await send(env, chatId, `⛔ ${nameOf(user)} 警告满 ${limit} 次，已踢出`);
    return { ...(r || {}), banned: true };
  }
  await setWarns(env, chatId, user.id, n);
  return send(env, chatId, `⚠️ ${nameOf(user)}：${why}，警告 ${n}/${limit}（满 ${limit} 次踢出）`);
}

const ADMIN_CMDS = new Set(["/warn", "/unwarn", "/ban", "/mute", "/unmute", "/del"]);

async function adminCommand(env, msg, cmd, text) {
  const chatId = msg.chat.id;
  const target = msg.reply_to_message;
  // 命令本身删掉，群里干净
  await tg(env, "deleteMessage", { chat_id: chatId, message_id: msg.message_id });
  if (!target) return send(env, chatId, `用法：回复要处理的那条消息，再发 ${cmd}`);

  const who = target.from;
  if (cmd === "/del") {
    return tg(env, "deleteMessage", { chat_id: chatId, message_id: target.message_id });
  }
  if (!who || who.is_bot && who.id === (await getMe(env)).id) return;
  if (await isAdmin(env, chatId, who.id)) return send(env, chatId, "管理员不能处理。");

  if (cmd === "/warn") {
    await tg(env, "deleteMessage", { chat_id: chatId, message_id: target.message_id });
    return warn(env, chatId, who, "管理员警告");
  }
  if (cmd === "/unwarn") {
    await setWarns(env, chatId, who.id, 0);
    return send(env, chatId, `✅ 已清掉 ${nameOf(who)} 的警告`);
  }
  if (cmd === "/ban") {
    await tg(env, "deleteMessage", { chat_id: chatId, message_id: target.message_id });
    await tg(env, "banChatMember", { chat_id: chatId, user_id: who.id, revoke_messages: true });
    return send(env, chatId, `⛔ 已踢出 ${nameOf(who)}`);
  }
  if (cmd === "/mute") {
    const secs = parseDuration(text.split(/\s+/)[1]);
    const body = { chat_id: chatId, user_id: who.id, permissions: NO_PERMS };
    if (secs) body.until_date = Math.floor(Date.now() / 1000) + secs;
    await tg(env, "restrictChatMember", body);
    return send(env, chatId, `🔇 已禁言 ${nameOf(who)}${secs ? "（" + text.split(/\s+/)[1] + "）" : "（直到解禁）"}`);
  }
  if (cmd === "/unmute") {
    await tg(env, "restrictChatMember", { chat_id: chatId, user_id: who.id, permissions: ALL_PERMS });
    return send(env, chatId, `🔊 已解除 ${nameOf(who)} 的禁言`);
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

// 判广告用便宜的小模型：只要它回一个词，每条只花一点点额度。判不出来（出错）一律当不是广告，宁可漏不错杀。
const SPAM_MODEL = "@cf/meta/llama-3.1-8b-instruct-fast";

async function isSpam(env, text) {
  if (!env.AI) return false;
  try {
    const r = await env.AI.run(env.SPAM_MODEL || SPAM_MODEL, {
      messages: [
        {
          role: "system",
          content:
            "你是 Telegram 群的反垃圾审核。判断用户这条消息是不是广告、引流、诈骗、色情、赌博、刷单、" +
            "卖号卖卡、拉人进别的群或频道、加微信 / QQ / 私聊领福利。正常聊天、提问、讨论技术、分享经验都不算。" +
            "只回答一个词：SPAM 或 OK。",
        },
        { role: "user", content: text.slice(0, 1500) },
      ],
      max_tokens: 5,
    });
    return /\bSPAM\b/i.test(cleanReply(pickText(r)));
  } catch (e) {
    console.log("spam check failed:", e?.message || e);
    return false;
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
