const http = require("http");
const fs = require("fs");
const path = require("path");

const SUPABASE_URL = process.env.SUPABASE_URL || "https://nuuebvpsfcgsgkefecab.supabase.co";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const AUTH_EMAIL_DOMAIN = "leadcontrol.local";
const PORT = Number(process.env.PORT || 5173);

const publicFiles = new Map([
  ["/", "index.html"],
  ["/index.html", "index.html"],
  ["/styles.css", "styles.css"],
  ["/app.js", "app.js"],
]);

if (!SUPABASE_SERVICE_ROLE_KEY) {
  console.error("Defina SUPABASE_SERVICE_ROLE_KEY antes de iniciar o servidor.");
  process.exit(1);
}

const server = http.createServer(async (request, response) => {
  try {
    const requestUrl = new URL(request.url, `http://${request.headers.host || "localhost"}`);

    if (request.method === "OPTIONS") {
      sendJson(response, 200, {});
      return;
    }

    if (requestUrl.pathname === "/api/ensure-profile" && request.method === "POST") {
      await ensureProfile(request, response);
      return;
    }

    if (requestUrl.pathname === "/api/create-store" && request.method === "POST") {
      await createStore(request, response);
      return;
    }

    if (requestUrl.pathname === "/api/options" && request.method === "GET") {
      await getOptions(request, response, requestUrl);
      return;
    }

    if (
      requestUrl.pathname === "/api/options" &&
      (request.method === "POST" || request.method === "PUT")
    ) {
      await saveOptions(request, response, requestUrl);
      return;
    }

    serveStatic(request, response);
  } catch (error) {
    sendJson(response, error.status || 500, { error: error.message || "Erro interno." });
  }
});

server.listen(PORT, () => {
  console.log(`Controle de Leads rodando em http://localhost:${PORT}`);
});

async function ensureProfile(request, response) {
  const user = await getUserFromRequest(request);
  const existingProfile = await supabaseGet(`/rest/v1/profiles?id=eq.${user.id}&select=id`);

  if (existingProfile.length) {
    sendJson(response, 200, { ok: true });
    return;
  }

  await supabaseRequest("/rest/v1/profiles", {
    method: "POST",
    headers: {
      Prefer: "return=minimal",
    },
    body: {
      id: user.id,
      email: user.email || nickToAuthEmail("admin"),
      role: "admin",
      store_id: null,
    },
  });

  sendJson(response, 200, { ok: true });
}

async function createStore(request, response) {
  const user = await getUserFromRequest(request);
  const profile = await getProfile(user.id);

  if (profile?.role !== "admin") {
    sendJson(response, 403, { error: "Apenas admin pode criar lojas." });
    return;
  }

  const body = await readJson(request);
  const name = String(body.name || "").trim();
  const username = normalizeNick(body.username || "");
  const password = String(body.password || "");
  const email = nickToAuthEmail(username);

  if (!name || !username || password.length < 6) {
    sendJson(response, 400, { error: "Nome, nick e senha com 6 caracteres são obrigatórios." });
    return;
  }

  if (await authUserExists(email)) {
    sendJson(response, 409, { error: "Esse nick já está cadastrado." });
    return;
  }

  if (await storeExists(email)) {
    sendJson(response, 409, { error: "Já existe uma loja com esse nick." });
    return;
  }

  const store = await insertStore({ name, email, created_by: user.id });

  try {
    const leadOptions = normalizeLeadOptions(user.user_metadata?.lead_options);
    const authUser = await createAuthUser({ email, password, name, storeId: store.id, leadOptions });
    await updateStoreUser(store.id, authUser.id);
    await upsertStoreProfile({ id: authUser.id, email, storeId: store.id });

    sendJson(response, 200, {
      store: {
        ...store,
        auth_user_id: authUser.id,
      },
    });
  } catch (error) {
    await supabaseRequest(`/rest/v1/stores?id=eq.${store.id}`, { method: "DELETE" });
    sendJson(response, 400, { error: error.message || "Não foi possível criar a loja." });
  }
}

async function getOptions(request, response, requestUrl) {
  const user = await getUserFromRequest(request);
  const targetUser = await getTargetOptionsUser(user, requestUrl.searchParams.get("store_id"));

  sendJson(response, 200, {
    options: normalizeLeadOptions(targetUser.user_metadata?.lead_options),
  });
}

async function saveOptions(request, response, requestUrl) {
  const user = await getUserFromRequest(request);
  const storeId = requestUrl.searchParams.get("store_id");
  const targetUser = await getTargetOptionsUser(user, storeId);
  const body = await readJson(request);
  const leadOptions = normalizeLeadOptions(body.options);

  await updateUserMetadata(targetUser.id, {
    ...(targetUser.user_metadata || {}),
    lead_options: leadOptions,
  });

  const profile = await getProfile(user.id);
  if (!storeId && profile?.role === "admin") {
    await propagateLeadOptionsToStores(leadOptions);
  }

  sendJson(response, 200, { options: leadOptions });
}

async function getTargetOptionsUser(user, storeId) {
  if (!storeId) return user;

  const profile = await getProfile(user.id);
  if (profile?.role !== "admin") {
    throw Object.assign(new Error("Apenas admin pode editar opções de outra loja."), {
      status: 403,
    });
  }

  const stores = await supabaseGet(
    `/rest/v1/stores?id=eq.${encodeURIComponent(storeId)}&select=id,auth_user_id&limit=1`,
  );
  const authUserId = stores[0]?.auth_user_id;

  if (!authUserId) {
    throw Object.assign(new Error("Loja sem usuário vinculado."), { status: 404 });
  }

  return getAdminUser(authUserId);
}

async function getUserFromRequest(request) {
  const token = request.headers.authorization?.replace("Bearer ", "");

  if (!token) {
    throw Object.assign(new Error("Sessão obrigatória."), { status: 401 });
  }

  const result = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${token}`,
    },
  });

  if (!result.ok) {
    throw Object.assign(new Error("Sessão inválida."), { status: 401 });
  }

  return result.json();
}

async function getAdminUser(userId) {
  const result = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}`, {
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    },
  });

  const payload = await result.json();
  if (!result.ok) {
    throw Object.assign(new Error(payload.msg || payload.message || "Usuário não encontrado."), {
      status: result.status,
    });
  }

  return payload;
}

async function propagateLeadOptionsToStores(leadOptions) {
  const stores = await supabaseGet("/rest/v1/stores?select=auth_user_id&auth_user_id=not.is.null");

  for (const store of stores) {
    const storeUser = await getAdminUser(store.auth_user_id);
    await updateUserMetadata(storeUser.id, {
      ...(storeUser.user_metadata || {}),
      lead_options: leadOptions,
    });
  }
}

async function getProfile(userId) {
  const profiles = await supabaseGet(`/rest/v1/profiles?id=eq.${userId}&select=id,email,role,store_id`);
  return profiles[0] || null;
}

async function insertStore(store) {
  const stores = await supabaseRequest("/rest/v1/stores?select=id,name,email,created_at", {
    method: "POST",
    headers: {
      Prefer: "return=representation",
    },
    body: store,
  });

  return stores[0];
}

async function createAuthUser({ email, password, name, storeId, leadOptions }) {
  const result = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
    method: "POST",
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      email,
      password,
      email_confirm: true,
      app_metadata: {
        role: "store",
        store_id: storeId,
      },
      user_metadata: {
        store_name: name,
        username: emailToNick(email),
        lead_options: normalizeLeadOptions(leadOptions),
      },
    }),
  });

  const payload = await result.json();
  if (!result.ok) {
    throw new Error(payload.msg || payload.message || payload.error_description || "Erro ao criar usuário.");
  }

  return payload;
}

async function updateUserMetadata(userId, metadata) {
  const result = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}`, {
    method: "PUT",
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      user_metadata: metadata,
    }),
  });

  const payload = await result.json();
  if (!result.ok) {
    throw new Error(payload.msg || payload.message || "Erro ao salvar opções.");
  }

  return payload;
}

async function authUserExists(email) {
  const result = await fetch(
    `${SUPABASE_URL}/auth/v1/admin/users?page=1&per_page=1000`,
    {
      headers: {
        apikey: SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      },
    },
  );

  const payload = await result.json();
  if (!result.ok) return false;

  const users = Array.isArray(payload) ? payload : payload.users || [];
  return users.some((user) => user.email === email);
}

async function storeExists(email) {
  const stores = await supabaseGet(
    `/rest/v1/stores?email=eq.${encodeURIComponent(email)}&select=id&limit=1`,
  );
  return stores.length > 0;
}

async function updateStoreUser(storeId, userId) {
  await supabaseRequest(`/rest/v1/stores?id=eq.${storeId}`, {
    method: "PATCH",
    headers: {
      Prefer: "return=minimal",
    },
    body: {
      auth_user_id: userId,
    },
  });
}

async function upsertStoreProfile({ id, email, storeId }) {
  await supabaseRequest("/rest/v1/profiles", {
    method: "POST",
    headers: {
      Prefer: "resolution=merge-duplicates,return=minimal",
    },
    body: {
      id,
      email,
      role: "store",
      store_id: storeId,
    },
  });
}

async function supabaseGet(pathname) {
  return supabaseRequest(pathname, { method: "GET" });
}

async function supabaseRequest(pathname, options = {}) {
  const result = await fetch(`${SUPABASE_URL}${pathname}`, {
    method: options.method || "GET",
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });

  const text = await result.text();
  const payload = text ? JSON.parse(text) : null;

  if (!result.ok) {
    throw new Error(payload?.message || payload?.msg || payload?.error || "Erro no Supabase.");
  }

  return payload;
}

function serveStatic(request, response) {
  const file = publicFiles.get(request.url.split("?")[0]);
  if (!file) {
    response.writeHead(404);
    response.end("Arquivo não encontrado.");
    return;
  }

  const fullPath = path.join(__dirname, file);
  const ext = path.extname(fullPath);
  const contentType =
    ext === ".css" ? "text/css" : ext === ".js" ? "text/javascript" : "text/html";

  response.writeHead(200, {
    "Content-Type": `${contentType}; charset=utf-8`,
  });
  fs.createReadStream(fullPath).pipe(response);
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.on("data", (chunk) => {
      body += chunk;
    });
    request.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function sendJson(response, status, payload) {
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
  });
  response.end(JSON.stringify(payload));
}

function nickToAuthEmail(nick) {
  return `${normalizeNick(nick)}@${AUTH_EMAIL_DOMAIN}`;
}

function emailToNick(email) {
  return String(email || "").split("@")[0] || "";
}

function normalizeNick(value) {
  return String(value)
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9._-]/g, "")
    .replace(/^[._-]+|[._-]+$/g, "");
}

function normalizeLeadOptions(value) {
  const source = value && typeof value === "object" ? value : {};
  return {
    channel: normalizeOptionList(source.channel),
    campaign: normalizeOptionList(source.campaign),
    conversationStart: normalizeOptionList(source.conversationStart),
    conclusion: normalizeOptionList(source.conclusion),
    visited: normalizeOptionList(source.visited),
    bought: normalizeOptionList(source.bought),
  };
}

function normalizeOptionList(value) {
  if (!Array.isArray(value)) return [];
  const cleanValues = value
    .map((item) => String(item || "").trim())
    .filter(Boolean);

  return [...new Set(cleanValues)];
}
