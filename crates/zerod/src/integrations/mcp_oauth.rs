//! Zero's own sign-ins to the remote MCP servers the user keeps in Zero (MCP's OAuth: the server's protected-resource
//! metadata, its authorization server's, a client registered for each sign-in, PKCE), their tokens in the vault with
//! the others. A task's CLI is given the access token as an Authorization header, for the server's URL alone. MCP
//! servers aren't the CLIs' providers, so this is Zero's to do.

use std::collections::HashMap;

use super::*;

/// A server's sign-in: none yet (`access` empty, the user asked), or its tokens. Kept for the URL it was made for.
#[derive(Serialize, Deserialize, Clone, Default, Debug)]
pub struct McpToken {
    pub resource: String,
    #[serde(default)]
    token_endpoint: String,
    #[serde(default)]
    client_id: String,
    #[serde(default)]
    access: Option<String>,
    #[serde(default)]
    refresh: Option<String>,
    #[serde(default)]
    expires: i64,
}

/// What an authorization server says of itself, as far as signing in goes.
struct Endpoints {
    authorize: String,
    token: String,
    register: String,
    scopes: Vec<String>,
}

impl Integrations {
    /// A server's sign-in for `url`: none known (None), waiting for the user (Some(None)), or its access token.
    pub fn mcp_access(&self, id: &str, url: &str) -> Option<Option<String>> {
        let tokens = self.mcp.lock().unwrap();
        tokens.get(id).filter(|t| t.resource == url).map(|t| t.access.clone())
    }

    /// The server at `url` answers without a token with a Bearer challenge: it's signed in to.
    pub async fn mcp_needs_sign_in(&self, url: &str) -> bool {
        let config = curl_config(url, None, r#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#, "application/json")
            + "header = \"Accept: application/json, text/event-stream\"\n";
        matches!(call(&*self.fetcher, config).await, Ok((401, challenge, _)) if challenge.to_lowercase().starts_with("bearer"))
    }

    /// Zero can sign in to the server at `url` itself: it asks for a sign-in, and its authorization server registers
    /// clients (Zero registers one for each sign-in).
    pub async fn mcp_zero_signs_in(&self, url: &str) -> bool {
        self.mcp_needs_sign_in(url).await && self.endpoints(url).await.is_ok()
    }

    /// `id` waits for the user to sign in to it at `url`: until then tasks aren't given it (a CLI given it without a
    /// token would note it as needing a sign-in of its own, and skip it for a while after).
    pub fn mcp_waiting(&self, id: &str, url: &str) {
        let token = McpToken { resource: url.into(), ..Default::default() };
        self.keep_mcp(id, Some(token))
    }

    /// Zero's sign-in to `id` at `url`: its page to `page`, then the browser back on a port of zerod's own, and the
    /// tokens kept. Dropped (timed out), the port goes with it.
    pub async fn mcp_sign_in(&self, id: &str, url: &str, page: tokio::sync::oneshot::Sender<String>) -> Result<(), String> {
        let endpoints = self.endpoints(url).await?;
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.map_err(|e| format!("Can't listen for the sign-in: {e}"))?;
        let redirect = format!("http://127.0.0.1:{}/callback", listener.local_addr().map_err(|e| e.to_string())?.port());
        let registration = json!({"client_name": "Zero", "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
                                  "response_types": ["code"], "token_endpoint_auth_method": "none"});
        let (_, _, registered) =
            call(&*self.fetcher, curl_config(&endpoints.register, None, &registration.to_string(), "application/json")).await?;
        let client_id = registered["client_id"].as_str().ok_or_else(|| format!("{id} registered no client: {registered}"))?.to_string();
        let (verifier, state) = (random(), random());
        let challenge = base64url(&sha256(verifier.as_bytes()));
        let mut form = vec![
            ("response_type", "code"),
            ("client_id", &client_id),
            ("redirect_uri", &redirect),
            ("state", &state),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("resource", url),
        ];
        let scope = endpoints.scopes.join(" ");
        if !scope.is_empty() {
            form.push(("scope", &scope))
        }
        let _ = page.send(format!("{}?{}", endpoints.authorize, encode_form(&form)));
        let code = loop {
            let (mut stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
            let mut line = String::new();
            let (read, mut write) = stream.split();
            let _ = BufReader::new(read).read_line(&mut line).await;
            let query: HashMap<String, String> =
                line.split_whitespace().nth(1).and_then(|path| path.split_once('?')).map(|(_, q)| decode_form(q)).unwrap_or_default();
            let code = query.get("code").filter(|_| query.get("state") == Some(&state)).cloned();
            let text = match &code {
                Some(_) => format!("Zero signed in to {id}. You can close this tab."),
                None => format!(
                    "Zero didn't sign in to {id}: {}",
                    query.get("error_description").or(query.get("error")).map_or("not this sign-in", |s| s)
                ),
            };
            let page = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}",
                text.len()
            );
            let _ = write.write_all(page.as_bytes()).await;
            let _ = write.shutdown().await;
            if let Some(code) = code {
                break code;
            }
        };
        let form = encode_form(&[
            ("grant_type", "authorization_code"),
            ("code", &code),
            ("redirect_uri", &redirect),
            ("client_id", &client_id),
            ("code_verifier", &verifier),
            ("resource", url),
        ]);
        let token = McpToken { resource: url.into(), token_endpoint: endpoints.token, client_id, ..Default::default() };
        let token = self.tokens(token, &form).await?;
        self.keep_mcp(id, Some(token));
        Ok(())
    }

    /// Every sign-in running out within 5 minutes refreshed, once each; one refused is let go (its server is given as
    /// it is, and says it needs signing in again). The servers whose token changed.
    pub async fn refresh_mcp(&self) -> Vec<String> {
        let due: Vec<(String, McpToken)> = {
            let tokens = self.mcp.lock().unwrap();
            tokens
                .iter()
                .filter(|(_, t)| t.access.is_some() && t.refresh.is_some() && t.expires <= now() + 300)
                .map(|(id, t)| (id.clone(), t.clone()))
                .collect()
        };
        let mut changed = vec![];
        for (id, token) in due {
            let refresh = token.refresh.clone().unwrap_or_default();
            let form = encode_form(&[
                ("grant_type", "refresh_token"),
                ("refresh_token", &refresh),
                ("client_id", &token.client_id),
                ("resource", &token.resource),
            ]);
            match self.tokens(token, &form).await {
                Ok(token) => self.keep_mcp(&id, Some(token)),
                Err(error) => {
                    eprintln!("zerod: couldn't refresh the sign-in to {id}: {error}");
                    self.keep_mcp(&id, None)
                }
            }
            changed.push(id)
        }
        changed
    }

    /// A server's sign-in let go (the server deleted).
    pub fn forget_mcp(&self, id: &str) {
        if self.mcp.lock().unwrap().contains_key(id) {
            self.keep_mcp(id, None)
        }
    }

    /// When the soonest sign-in needs refreshing, in seconds since 1970.
    pub fn mcp_refresh_due(&self) -> Option<i64> {
        self.mcp.lock().unwrap().values().filter(|t| t.access.is_some() && t.refresh.is_some()).map(|t| t.expires - 300).min()
    }

    fn keep_mcp(&self, id: &str, token: Option<McpToken>) {
        let _saving = self.saving.lock().unwrap();
        match token {
            Some(token) => self.mcp.lock().unwrap().insert(id.into(), token),
            None => self.mcp.lock().unwrap().remove(id),
        };
        if let Err(error) = self.save() {
            eprintln!("zerod: couldn't keep the sign-in to {id}: {error}")
        }
    }

    /// `token` with what its token endpoint gives for `form`: a refresh token not given again is kept.
    async fn tokens(&self, mut token: McpToken, form: &str) -> Result<McpToken, String> {
        let (status, _, reply) =
            call(&*self.fetcher, curl_config(&token.token_endpoint, None, form, "application/x-www-form-urlencoded")).await?;
        let access = reply["access_token"].as_str().filter(|_| status < 400).ok_or_else(|| {
            reply["error_description"].as_str().or(reply["error"].as_str()).map_or(format!("no token ({status})"), String::from)
        })?;
        token.access = Some(access.into());
        token.refresh = reply["refresh_token"].as_str().map(String::from).or(token.refresh);
        token.expires = now() + reply["expires_in"].as_i64().unwrap_or(10 * 365 * 86400);
        Ok(token)
    }

    /// Where `url`'s sign-in is: its protected-resource metadata (named in its challenge, else at its well-known
    /// place), then its authorization server's.
    async fn endpoints(&self, url: &str) -> Result<Endpoints, String> {
        let get = |at: String| call(&*self.fetcher, format!("url = \"{at}\"\n"));
        let config = curl_config(url, None, r#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#, "application/json")
            + "header = \"Accept: application/json, text/event-stream\"\n";
        let (_, challenge, _) = call(&*self.fetcher, config).await?;
        let named = challenge.split("resource_metadata=\"").nth(1).and_then(|rest| rest.split('"').next()).map(String::from);
        let (origin, path) = split_url(url);
        let (_, _, resource) = get(named.unwrap_or_else(|| format!("{origin}/.well-known/oauth-protected-resource{path}"))).await?;
        let issuer = resource["authorization_servers"][0].as_str().map(String::from).unwrap_or(origin);
        let (origin, path) = split_url(&issuer);
        let (mut status, _, mut server) = get(format!("{origin}/.well-known/oauth-authorization-server{path}")).await?;
        if status >= 400 || !server.is_object() {
            (status, _, server) = get(format!("{origin}/.well-known/openid-configuration{path}")).await?;
        }
        let field = |name: &str| server[name].as_str().map(String::from).ok_or_else(|| format!("{issuer} gives no {name} ({status})"));
        Ok(Endpoints {
            authorize: field("authorization_endpoint")?,
            token: field("token_endpoint")?,
            register: field("registration_endpoint")?,
            scopes: resource["scopes_supported"].as_array().into_iter().flatten().filter_map(|s| s.as_str().map(String::from)).collect(),
        })
    }
}

/// One request (curl's config on its stdin): its status, its WWW-Authenticate, and its body as JSON (null if it isn't).
async fn call(fetcher: &dyn Fetcher, config: String) -> Result<(u16, String, Value), String> {
    let config = config + "write-out = \"\\n%{http_code}|%header{www-authenticate}\"\n";
    let printed = fetcher.run(["curl", "-sS", "-K", "-"].map(String::from).to_vec(), Some(config)).await?;
    let (body, last) = printed.rsplit_once('\n').unwrap_or(("", &printed));
    let (status, challenge) = last.split_once('|').unwrap_or((last, ""));
    Ok((status.trim().parse().unwrap_or(0), challenge.trim().into(), serde_json::from_str(body).unwrap_or(Value::Null)))
}

/// A URL's origin, and its path without a trailing slash ("" for none).
fn split_url(url: &str) -> (String, String) {
    let after = url.find("://").map_or(0, |i| i + 3);
    let (origin, path) = url[after..].find('/').map_or((url, ""), |i| url.split_at(after + i));
    (origin.into(), path.trim_end_matches('/').into())
}
