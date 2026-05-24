// All logic for the matchmaking UI lives here. Kept in one file deliberately —
// see prd.md for the multi-module layout we may adopt later.

const POLL_INTERVAL_MS = 4000;
const VIEWS = ["login", "register", "lobby", "search", "found", "game"];
const $ = (id) => document.getElementById(id);

const session = {
  idToken: sessionStorage.getItem("idToken") || null,
  email: sessionStorage.getItem("email") || null,
  userId: sessionStorage.getItem("userId") || null,
  ticketId: null,
  searchStartedAt: 0,
  pollTimer: null,
  elapsedTimer: null,
  lastMatch: null,
};

function showView(name) {
  for (const v of VIEWS) $(`view-${v}`).classList.toggle("hidden", v !== name);
}

function setToken(idToken, email) {
  session.idToken = idToken;
  session.email = email;
  if (idToken) {
    sessionStorage.setItem("idToken", idToken);
    sessionStorage.setItem("email", email || "");
  } else {
    session.userId = null;
    sessionStorage.removeItem("idToken");
    sessionStorage.removeItem("email");
    sessionStorage.removeItem("userId");
  }
}

// ── Cognito InitiateAuth (USER_PASSWORD_AUTH) ───────────────────────────────
async function cognitoLogin(email, password) {
  const url = `https://cognito-idp.${CONFIG.region}.amazonaws.com/`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-amz-json-1.1",
      "X-Amz-Target": "AWSCognitoIdentityProviderService.InitiateAuth",
    },
    body: JSON.stringify({
      AuthFlow: "USER_PASSWORD_AUTH",
      ClientId: CONFIG.clientId,
      AuthParameters: { USERNAME: email, PASSWORD: password },
    }),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.message || `Login failed (${res.status})`);
  }
  const data = await res.json();
  return data.AuthenticationResult.IdToken;
}

// ── API client ──────────────────────────────────────────────────────────────
async function api(path, options = {}) {
  const res = await fetch(`${CONFIG.apiUrl}${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.idToken}`,
      ...(options.headers || {}),
    },
  });
  if (res.status === 401) {
    setToken(null, null);
    showView("login");
    throw new Error("Session expired — please sign in again.");
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `Request failed (${res.status})`);
  return body;
}

// ── Register ────────────────────────────────────────────────────────────────
$("show-register-btn").addEventListener("click", () => {
  $("register-error").textContent = "";
  showView("register");
});
$("show-login-btn").addEventListener("click", () => {
  $("login-error").textContent = "";
  showView("login");
});

$("register-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const email = $("reg-email").value.trim();
  const username = $("reg-username").value.trim();
  const password = $("reg-password").value;
  const elo = parseInt($("reg-elo").value, 10);
  $("register-error").textContent = "";
  try {
    const res = await fetch(`${CONFIG.apiUrl}/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, username, password, elo }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || `Registration failed (${res.status})`);
    // Drop user back at the login screen with the email prefilled.
    $("login-email").value = email;
    $("login-password").value = "";
    $("login-info").textContent = `Account created for ${email}. Please sign in.`;
    showView("login");
  } catch (err) {
    $("register-error").textContent = err.message;
  }
});

// ── Login ───────────────────────────────────────────────────────────────────
$("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const email = $("login-email").value.trim();
  const password = $("login-password").value;
  $("login-error").textContent = "";
  $("login-info").textContent = "";
  try {
    const token = await cognitoLogin(email, password);
    setToken(token, email);
    await enterLobby();
  } catch (err) {
    $("login-error").textContent = err.message;
  }
});

// ── Lobby ───────────────────────────────────────────────────────────────────
async function enterLobby(message = "") {
  showView("lobby");
  $("lobby-message").textContent = message;
  $("lobby-email").textContent = session.email || "(unknown)";
  $("lobby-username").textContent = "…";
  $("lobby-elo").textContent = "…";
  $("lobby-wins").textContent = "…";
  $("lobby-losses").textContent = "…";
  try {
    const profile = await api("/profile");
    $("lobby-username").textContent = profile.username || "(no username)";
    $("lobby-elo").textContent = profile.elo;
    $("lobby-wins").textContent = profile.wins;
    $("lobby-losses").textContent = profile.losses;
    if (profile.userId) {
      session.userId = profile.userId;
      sessionStorage.setItem("userId", profile.userId);
    }
    if (!session.email && profile.email) {
      session.email = profile.email;
      sessionStorage.setItem("email", profile.email);
      $("lobby-email").textContent = profile.email;
    }
  } catch (err) {
    $("lobby-message").textContent = `Could not load profile: ${err.message}`;
  }
}

$("find-match-btn").addEventListener("click", async () => {
  $("lobby-message").textContent = "";
  try {
    const ticket = await api("/match", { method: "POST" });
    session.ticketId = ticket.ticketId;
    session.searchStartedAt = Date.now();
    enterSearch();
  } catch (err) {
    $("lobby-message").textContent = err.message;
  }
});

$("logout-btn").addEventListener("click", () => {
  setToken(null, null);
  showView("login");
});

// ── Search ──────────────────────────────────────────────────────────────────
function enterSearch() {
  showView("search");
  $("search-elapsed").textContent = "0s";
  session.elapsedTimer = setInterval(() => {
    const secs = Math.floor((Date.now() - session.searchStartedAt) / 1000);
    $("search-elapsed").textContent = `${secs}s`;
  }, 1000);
  session.pollTimer = setInterval(pollTicket, POLL_INTERVAL_MS);
  pollTicket();
}

function stopSearch() {
  clearInterval(session.pollTimer);
  clearInterval(session.elapsedTimer);
  session.pollTimer = null;
  session.elapsedTimer = null;
}

async function pollTicket() {
  if (!session.ticketId) return;
  try {
    const status = await api(`/match/${session.ticketId}`);
    if (status.status === "SUCCEEDED") {
      stopSearch();
      session.lastMatch = status;
      enterFound(status);
    } else if (status.status === "TIMED_OUT") {
      stopSearch();
      session.ticketId = null;
      enterLobby("Search timed out. Try again in a moment.");
    } else if (status.status === "CANCELLED") {
      stopSearch();
      session.ticketId = null;
      enterLobby("Search cancelled.");
    }
  } catch (err) {
    stopSearch();
    enterLobby(err.message);
  }
}

$("cancel-btn").addEventListener("click", async () => {
  if (!session.ticketId) return;
  try {
    await api(`/match/${session.ticketId}`, { method: "DELETE" });
  } catch (err) {
    // Even on error, return to lobby — the user clearly wants out.
    console.warn("cancel failed:", err);
  }
  stopSearch();
  session.ticketId = null;
  enterLobby("Search cancelled.");
});

// ── Match Found ─────────────────────────────────────────────────────────────
function renderPlayerList(listEl, match) {
  listEl.innerHTML = "";
  const players = match.players && match.players.length
    ? match.players
    : (match.matchedPlayers || []).map((id) => ({ userId: id, username: id }));
  const opponents = players.filter((p) => p.userId !== session.userId);
  if (opponents.length === 0) {
    const li = document.createElement("li");
    li.className = "muted";
    li.textContent = "(no other players)";
    listEl.appendChild(li);
    return;
  }
  for (const p of opponents) {
    const li = document.createElement("li");
    li.textContent = p.username || p.userId;
    listEl.appendChild(li);
  }
}

function enterFound(match) {
  showView("found");
  const addr = `${match.serverIp}:${match.serverPort}`;
  $("found-server").textContent = addr;
  $("found-connect-cmd").textContent = `/connect ${match.serverIp} ${match.serverPort}`;
  renderPlayerList($("found-players"), match);
}

$("connect-btn").addEventListener("click", () => {
  if (!session.lastMatch) return;
  enterGame(session.lastMatch);
});

$("return-btn").addEventListener("click", () => {
  session.lastMatch = null;
  session.ticketId = null;
  enterLobby();
});

// ── Game Session (dummy) ────────────────────────────────────────────────────
function enterGame(match) {
  showView("game");
  $("game-server").textContent = `${match.serverIp}:${match.serverPort}`;
  renderPlayerList($("game-players"), match);
}

$("leave-btn").addEventListener("click", () => {
  session.lastMatch = null;
  session.ticketId = null;
  enterLobby("You left the game.");
});

// ── Bootstrap ───────────────────────────────────────────────────────────────
if (typeof CONFIG === "undefined" || !CONFIG.apiUrl || !CONFIG.clientId || !CONFIG.region) {
  document.body.innerHTML =
    "<main><h1>Configuration missing</h1><p>config.js was not generated. Run <code>scripts/deploy-ui.sh</code>.</p></main>";
} else if (session.idToken) {
  enterLobby();
} else {
  showView("login");
}
