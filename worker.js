// worker.js
// Cloudflare Workers + Telegram Bot Webhook + Cloudflare Workers AI (free-tier)
// Required Secret: TELEGRAM_BOT_TOKEN
// Optional Secret: SYSTEM_PROMPT

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === "/") {
      return new Response("ok", { status: 200 });
    }

    // Telegram webhook endpoint
    if (url.pathname === "/telegram") {
      if (request.method !== "POST") {
        return new Response("Method Not Allowed", { status: 405 });
      }

      const update = await request.json().catch(() => null);
      if (!update) return new Response("Bad Request", { status: 400 });

      const msg = update.message || update.edited_message;
      if (!msg || !msg.chat) return new Response("ok", { status: 200 });

      const chatId = msg.chat.id;
      const text = (msg.text || "").trim();

      // Ignore non-text messages for now (stickers, photos, etc.)
      if (!text) return new Response("ok", { status: 200 });

      // Commands
      if (text === "/start") {
        await tgSend(env, chatId, "我在。直接发消息，我会像AI一样跟你聊（免费模型）。\n\n命令：/help /ping /reset");
        return new Response("ok", { status: 200 });
      }

      if (text === "/help") {
        await tgSend(
          env,
          chatId,
          [
            "可用命令：",
            "/ping  测试是否在线",
            "/reset 清空（当前版本不保存上下文，这个只是占位）",
            "",
            "直接发文字，我会回复。",
          ].join("\n")
        );
        return new Response("ok", { status: 200 });
      }

      if (text === "/ping") {
        await tgSend(env, chatId, "pong ✅ 我在线");
        return new Response("ok", { status: 200 });
      }

      if (text === "/reset") {
        await tgSend(env, chatId, "已重置 ✅（当前版本是单轮对话，不保存历史）");
        return new Response("ok", { status: 200 });
      }

      // Call Workers AI (free model)
      let reply = "";
      try {
        reply = await callWorkersAI(env, text);
      } catch (e) {
        reply = `出错了：${e?.message || e}`;
      }

      // Send reply
      await tgSend(env, chatId, reply || "（我收到了，但没生成出可读文本）");

      return new Response("ok", { status: 200 });
    }

    return new Response("Not Found", { status: 404 });
  },
};

// -------------------- Telegram helpers --------------------

async function tgSend(env, chatId, text) {
  const token = env.TELEGRAM_BOT_TOKEN;
  if (!token) {
    console.log("Missing TELEGRAM_BOT_TOKEN secret");
    return;
  }

  // Telegram message limit is ~4096 chars; keep it safe
  const safeText = String(text || "").slice(0, 3800);

  const api = `https://api.telegram.org/bot${token}/sendMessage`;
  const res = await fetch(api, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      chat_id: chatId,
      text: safeText,
      disable_web_page_preview: true,
    }),
  });

  if (!res.ok) {
    const t = await res.text().catch(() => "");
    console.log("tgSend failed:", res.status, t);
  }
}

// -------------------- Workers AI --------------------
//
// 「现在不智能了」的原因：原来用 8B 小模型 + 拼字符串的 prompt（"用户：…\n助手："）。
// 这种写法不走模型自己的对话模板，小模型会顺着往下编，自问自答出一串「用户：… 助手：… #标签」。
// 现在改成 messages（system / user 分开，走对话模板），默认换成中文好得多的 Qwen3 30B，
// 它出错 / 不可用时退回 Llama 3.3 70B。想换模型在 Worker 的变量里设 AI_MODEL，不用改代码。

const MODELS = [
  "@cf/qwen/qwen3-30b-a3b-fp8",
  "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
];

async function callWorkersAI(env, userText) {
  if (!env.AI) {
    throw new Error('Workers AI 未绑定：请在 wrangler.toml 添加 [ai]\nbinding="AI" 并重新部署');
  }

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
      const result = await env.AI.run(model, { messages, max_tokens: 1024 });
      const text = cleanReply(pickText(result));
      if (text) return text;
    } catch (e) {
      lastErr = e;
      console.log("AI model failed:", model, e?.message || e);
    }
  }
  if (lastErr) throw lastErr;
  return "";
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
