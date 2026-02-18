/// token_refresh.js — njs module for OpenClaw API proxy token management
///
/// Provides per-service token getters (read from env) and a js_periodic
/// handler that rotates the Google OAuth2 access token every 45 minutes.

/* eslint-disable no-unused-vars */

function get_telegram_token(r) {
  return process.env.TELEGRAM_BOT_TOKEN || "";
}

function get_brave_key(r) {
  return process.env.BRAVE_API_KEY || "";
}

function get_github_token(r) {
  return process.env.GITHUB_TOKEN || "";
}

function get_github_token_base64(r) {
  var token = process.env.GITHUB_TOKEN || "";
  if (!token) {
    return "";
  }
  return Buffer.from("x-access-token:" + token).toString("base64");
}

function get_google_token(r) {
  var zone = ngx.shared.google_tokens;
  return zone.get("access_token") || "";
}

function get_viber_token(r) {
  return process.env.VIBER_BOT_TOKEN || "";
}

function get_exa_key(r) {
  return process.env.EXA_API_KEY || "";
}

async function refresh_google_token(s) {
  var client_id = process.env.GOOGLE_CLIENT_ID || "";
  var client_secret = process.env.GOOGLE_CLIENT_SECRET || "";
  var refresh_token = process.env.GOOGLE_REFRESH_TOKEN || "";

  if (!client_id || !client_secret || !refresh_token) {
    ngx.log(ngx.WARN, "Google OAuth2 credentials not configured, skipping refresh");
    return;
  }

  var body =
    "client_id=" +
    encodeURIComponent(client_id) +
    "&client_secret=" +
    encodeURIComponent(client_secret) +
    "&refresh_token=" +
    encodeURIComponent(refresh_token) +
    "&grant_type=refresh_token";

  try {
    var resp = await ngx.fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body,
    });

    if (resp.status !== 200) {
      ngx.log(ngx.ERR, "Google token refresh HTTP " + resp.status);
      return;
    }

    var json = await resp.json();
    if (json.access_token) {
      ngx.shared.google_tokens.set("access_token", json.access_token);
      ngx.log(ngx.INFO, "Google OAuth2 token refreshed");
    } else {
      ngx.log(ngx.ERR, "Google token refresh: no access_token in response");
    }
  } catch (e) {
    ngx.log(ngx.ERR, "Google token refresh failed: " + e.message);
  }
}

export default {
  get_telegram_token,
  get_brave_key,
  get_github_token,
  get_github_token_base64,
  get_google_token,
  get_viber_token,
  get_exa_key,
  refresh_google_token,
};
