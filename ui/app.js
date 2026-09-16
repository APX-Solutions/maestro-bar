/* Maestro Bar — the interface, shared by the macOS and Windows apps.
 *
 * The native side owns the window, the token, the recorder and every HTTP
 * call. This file owns what is on screen. The two talk in small JSON messages:
 *
 *   web → native   ready · open · action · compose · ask · record · hide ·
 *                  drag · size · focus · open_url · copy · snip ·
 *                  snip_note · snip_discard
 *   native → web   state · rows · counts · recording · toast · answer ·
 *                  answer_error · escape · sent · snip_taken
 *
 * A card may carry more than its three lines: `status`, `progress` (0..1),
 * `eta`, `url`, `steps` [{label, state, note?, url?}], `actions` (which of
 * the section's buttons apply) and `live` (fetch this section again in a few
 * seconds). A section with `live` seconds is polled while any card is live;
 * one with `watch` is where a recording that was just sent shows up.
 *
 * Nothing here knows an endpoint. Sections, their actions and their compose
 * boxes arrive in `state`, straight from bar.json.
 */
(() => {
  "use strict";

  const $ = (sel) => document.querySelector(sel);
  const el = (tag, cls, html) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html !== undefined) n.innerHTML = html;
    return n;
  };
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  // ---- icons: one stroke, one size, drawn inline so both platforms match --
  const I = (path, extra = "") =>
    `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" ${extra}>${path}</svg>`;
  const icons = {
    grip: I('<circle cx="9" cy="6" r="1.3" fill="currentColor" stroke="none"/><circle cx="15" cy="6" r="1.3" fill="currentColor" stroke="none"/><circle cx="9" cy="12" r="1.3" fill="currentColor" stroke="none"/><circle cx="15" cy="12" r="1.3" fill="currentColor" stroke="none"/><circle cx="9" cy="18" r="1.3" fill="currentColor" stroke="none"/><circle cx="15" cy="18" r="1.3" fill="currentColor" stroke="none"/>'),
    close: I('<path d="M6 6l12 12M18 6L6 18"/>'),
    chevDown: I('<path d="M6 9l6 6 6-6"/>', 'width="16" height="16"'),
    chevUp: I('<path d="M6 15l6-6 6 6"/>', 'width="16" height="16"'),
    chevL: I('<path d="M15 6l-6 6 6 6"/>'),
    chevR: I('<path d="M9 6l6 6-6 6"/>'),
    mic: I('<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0014 0M12 18v3"/>'),
    screen: I('<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>'),
    stop: I('<rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor" stroke="none"/>'),
    inbox: I('<path d="M3 13h5l1.5 2.5h5L16 13h5M4.5 5h15l1.5 8v6h-18v-6z"/>'),
    pencil: I('<path d="M4 20h4L19 9l-4-4L4 16zM13 7l4 4"/>'),
    board: I('<rect x="3.5" y="4" width="4.5" height="16" rx="1.2"/><rect x="9.75" y="4" width="4.5" height="11" rx="1.2"/><rect x="16" y="4" width="4.5" height="13.5" rx="1.2"/>'),
    spark: I('<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 16l.8 2.2L22 19l-2.2.8L19 22l-.8-2.2L16 19l2.2-.8z"/>'),
    check: I('<path d="M5 12.5l4.5 4.5L19 7"/>'),
    send: I('<path d="M12 19V5M6 11l6-6 6 6"/>'),
    copy: I('<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a1 1 0 011-1h10"/>'),
    link: I('<path d="M14 4h6v6M20 4l-9 9M18 13v6a1 1 0 01-1 1H5a1 1 0 01-1-1V7a1 1 0 011-1h6"/>'),
    external: I('<path d="M14 4h6v6M20 4l-9 9"/>'),
    film: I('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 4v16M17 4v16M3 9h4M3 15h4M17 9h4M17 15h4"/>'),
    hammer: I('<path d="M14.5 5.5l4 4M17 3l4 4-2.5 2.5-4-4z"/><path d="M14.5 9.5L4 20l-1-1L13.5 8.5"/>'),
    camera: I('<path d="M3 8.5A1.5 1.5 0 014.5 7h2L8 5h8l1.5 2h2A1.5 1.5 0 0121 8.5v9A1.5 1.5 0 0119.5 19h-15A1.5 1.5 0 013 17.5z"/><circle cx="12" cy="12.5" r="3.2"/>'),
    fullscreen: I('<path d="M4 9V5a1 1 0 011-1h4M15 4h4a1 1 0 011 1v4M20 15v4a1 1 0 01-1 1h-4M9 20H5a1 1 0 01-1-1v-4"/>'),
  };
  // SF Symbol names in bar.json → the drawn set. Unknown names get a spark.
  const symbolIcon = (name = "") => {
    const n = name.toLowerCase();
    if (n.includes("board") || n.includes("kanban")) return icons.board;
    if (n.includes("film") || n.includes("story") || n.includes("clapper")) return icons.film;
    if (n.includes("tray") || n.includes("inbox")) return icons.inbox;
    if (n.includes("pencil") || n.includes("square.and")) return icons.pencil;
    if (n.includes("mic")) return icons.mic;
    if (n.includes("display") || n.includes("rectangle")) return icons.screen;
    if (n.includes("record")) return icons.mic;
    if (n.includes("check")) return icons.check;
    if (n.includes("hammer") || n.includes("wrench") || n.includes("build")) return icons.hammer;
    return icons.spark;
  };

  // ---- who may open the panel -------------------------------------------
  // The strip — record, screenshot, close — is for everyone. The panel behind
  // the chevron (review, sessions, capture, ask) is not, yet: only these
  // people see the chevron at all. Kept here rather than in bar.json because
  // the config on each machine is a copy made on first run and never
  // refreshed, while this file ships with every update of the app.
  const PANEL_EMAILS = new Set([
    "alexander@advertisable.ai",
    "tamara@advertisable.ai",
    "alex@advertisable.ai",
  ]);
  const panelAllowed = () => PANEL_EMAILS.has(state.user);

  // ---- state ------------------------------------------------------------
  const ASK = "ask";
  const state = {
    platform: "mac",
    user: "",              // the email the token belongs to, once /me has said
    hotkey: "",
    api: true,
    sections: [],          // [{id,title,symbol,hasList,actions:[{label,symbol}],compose:{placeholder,record}|null}]
    records: [],           // [{mode,label}]
    snip: true,            // show the screenshot button
    snipHint: "",          // its hot key, when there is one
    ask: null,             // {placeholder} when the brain can be asked
    recording: { active: false, mode: "", elapsed: "" },
    counts: {},
    active: null,          // section id, or ASK
    rows: {},              // section id → [{id,title,subtitle,body}]
    rowsAt: {},            // section id → when those rows arrived, so a stale list is refetched
    index: {},             // section id → current card
    loading: {},           // section id → true while the list is on its way
    thread: [],            // ask: [{role:'user'|'assistant', text, citations, error}]
    captures: [],          // this session's captures, newest first
    busy: false,           // an ask is in flight
    edge: "right",         // which side of the screen it is parked on
    askUrl: null,          // {mode} while a recording is asking where it is,
                           // or {kind:"snip"} while a screenshot asks what is wrong
    collapsed: true,       // parked folded: the panel is asked for, not imposed
    sending: null,         // {section, ids, at} while a recording is on its way to Maestro
    liveTimer: null,       // the poll, while a card is live
    liveFor: null,         // which section that poll is for
  };

  // ---- the bridge to the native side -------------------------------------
  const bridge = {
    send(msg) {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.maestro) {
        window.webkit.messageHandlers.maestro.postMessage(msg);
      } else if (window.__qt) {
        window.__qt.send(JSON.stringify(msg));
      } else if (window.__mock) {
        window.__mock(msg);
      }
    },
  };
  window.maestro = {
    receive(msg) {
      if (typeof msg === "string") { try { msg = JSON.parse(msg); } catch { return; } }
      handle(msg);
    },
  };

  function handle(m) {
    switch (m.type) {
      case "state": {
        state.platform = m.platform || "mac";
        state.edge = m.edge === "left" ? "left" : "right";
        state.hotkey = m.hotkey || "";
        state.api = m.api !== false;
        state.sections = m.sections || [];
        state.records = m.records || [];
        state.snip = m.snip !== false;       // the camera on the strip
        state.user = String(m.user || "").trim().toLowerCase();
        state.snipHint = m.snipHint || "";
        state.ask = m.ask || null;
        state.counts = m.counts || {};
        if (m.recording) state.recording = m.recording;
        const ids = state.sections.map((s) => s.id);
        if (!state.active || (state.active !== ASK && !ids.includes(state.active))) {
          state.active = ids[0] || (state.ask ? ASK : null);
        }
        render();
        // Someone the panel is not for must not be left inside it — the
        // token can change under a running bar, and so can the list.
        if (!panelAllowed() && !state.collapsed && !state.askUrl) setCollapsed(true);
        loadActive();
        break;
      }
      case "rows": {
        // A refresh keeps the card they were looking at: a live section
        // reloads every few seconds, and jumping to the first card each time
        // would make the third one unreadable.
        const before = state.rows[m.section];
        const heldId = before ? (before[state.index[m.section] || 0] || {}).id : null;
        const rows = m.rows || [];
        state.rows[m.section] = rows;
        state.rowsAt[m.section] = Date.now();
        const j = heldId ? rows.findIndex((r) => r.id === heldId) : -1;
        state.index[m.section] = j >= 0 ? j : Math.min(state.index[m.section] || 0, Math.max(0, rows.length - 1));
        state.loading[m.section] = false;
        state.counts[m.section] = rows.length;
        if (state.sending && state.sending.section === m.section) {
          // The recording has arrived as a card: the banner has done its job.
          if (rows.some((r) => !state.sending.ids.has(r.id))) state.sending = null;
          else if (Date.now() - state.sending.at > 4 * 60 * 1000) state.sending = null;
        }
        render();
        break;
      }
      case "counts": state.counts = Object.assign({}, state.counts, m.counts || {}); renderChips(); renderPill(); measure(); break;
      case "recording": state.recording = { active: !!m.active, mode: m.mode || "", elapsed: m.elapsed || "" }; renderPill(); renderTools(); measure(); break;
      case "toast": toast(m.text); break;
      case "answer": {
        state.busy = false;
        state.thread.push({ role: "assistant", text: m.text || "", citations: m.citations || [] });
        renderContent();
        break;
      }
      case "answer_error": {
        state.busy = false;
        state.thread.push({ role: "assistant", error: true, text: m.text || "Could not reach the brain." });
        renderContent();
        break;
      }
      case "snip_taken": {
        // The picture is already on disk. Now — and only now — the question:
        // asking first put the bar between the person and the thing they
        // were about to point at, and the words came before there was
        // anything to describe. Cancelled means nothing to ask about.
        if (!m.ok) break;
        state.askUrl = { kind: "snip", session: m.session || "", full: !!m.full };
        setCollapsed(false);
        render();
        const input = $("#input");
        if (input) { input.value = ""; setTimeout(() => input.focus(), 30); }
        break;
      }
      case "ask_url": {
        // A recording is about to start and the one thing it cannot capture
        // is the address of what is on screen. Ask here rather than in a
        // system dialog: the same question, inside the thing you just clicked.
        state.askUrl = { mode: m.mode || "audio" };
        setCollapsed(false);
        render();
        const box = $("#input");
        box.value = m.prefill || "";
        autosize();
        setTimeout(() => { box.focus(); box.select(); }, 30);
        break;
      }
      case "escape": onEscape(); break;
      case "sent": {
        // A recording is on its way. The section that watches recordings
        // says so and polls until the card for it appears.
        const w = state.sections.find((x) => x.watch);
        if (!w) break;
        state.sending = { section: w.id, ids: new Set((state.rows[w.id] || []).map((r) => r.id)), at: Date.now() };
        if (state.rows[w.id] === undefined && !state.loading[w.id]) {
          state.loading[w.id] = true;
          bridge.send({ type: "open", section: w.id });
        }
        render();
        break;
      }
      case "expand": setCollapsed(false); break;
      case "fold": setCollapsed(true); break;
      case "edge": state.edge = m.edge === "left" ? "left" : "right"; applyEdge(); measure(); break;
      default: break;
    }
  }

  // ---- helpers ------------------------------------------------------------
  const section = (id) => state.sections.find((s) => s.id === id) || null;
  const activeSection = () => (state.active === ASK ? null : section(state.active));
  const isWin = () => state.platform === "win";
  const modKey = () => (isWin() ? "Ctrl" : "⌘");
  const current = () => {
    const s = activeSection();
    if (!s || !s.hasList) return null;
    const rows = state.rows[s.id] || [];
    const i = state.index[s.id] || 0;
    return rows[i] || null;
  };

  // How long a section's rows are worth reusing. Opening a section used to
  // fetch ONCE, ever: rows were kept until the app restarted, so a card went on
  // showing what it said hours ago — a finished run still "running", a body the
  // server has since learned to send differently. Anything older than this is
  // refetched on the way in; anything newer is shown at once, so flicking
  // between chips stays instant.
  const ROWS_STALE_MS = 20000;

  function loadActive() {
    const s = activeSection();
    if (!s || !s.hasList) return;
    if (state.loading[s.id]) return;
    const age = Date.now() - (state.rowsAt[s.id] || 0);
    if (state.rows[s.id] !== undefined && age < ROWS_STALE_MS) return;
    state.loading[s.id] = state.rows[s.id] === undefined;   // spinner only when there is nothing to show
    bridge.send({ type: "open", section: s.id });
    renderContent();
  }

  function setActive(id) {
    state.active = id;
    setCollapsed(false);
    render();
    loadActive();
    $("#input").focus();
  }

  function setCollapsed(v) {
    // The panel opens for two reasons: to show its sections, or to ask a
    // question a recording or screenshot needs answered first. Only the
    // second is for everyone; the first is behind the chevron, and the
    // chevron is only drawn for the people on the list.
    if (!v && !state.askUrl && !panelAllowed()) v = true;
    state.collapsed = v;
    $("#root").classList.toggle("folded", v);
    renderPill();
    measure();
    if (!v) setTimeout(() => $("#input").focus(), 30);
  }

  /// The pill hugs the edge it is parked against, so folding the panel away
  /// does not slide it sideways.
  function applyEdge() {
    const r = $("#root");
    r.classList.toggle("edge-right", state.edge !== "left");
    r.classList.toggle("edge-left", state.edge === "left");
  }

  function onEscape() {
    if (state.askUrl) {
      // For a recording, Escape is Skip: the address is optional and the
      // person did press Record. For a screenshot the picture already
      // exists, and Escape on it means "never mind" — nothing should leave
      // the machine on a key that, everywhere else, backs out.
      if (state.askUrl.kind === "snip") discardSnip(); else answerUrl("");
      return;
    }
    if (!state.collapsed) setCollapsed(true);
    else bridge.send({ type: "hide" });
  }

  let toastTimer = null;
  function toast(text) {
    const t = $("#toast");
    t.textContent = text;
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, 2200);
  }

  const timeShort = (d) => d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

  // ---- render -------------------------------------------------------------
  function render() { applyEdge(); renderPill(); renderContent(); renderChips(); renderComposer(); measure(); syncLive(); }

  /// Fetch a section again every few seconds while one of its cards is live
  /// (a run in progress, a recording being read) or a recording was just
  /// sent. Stops the moment nothing is moving, so an idle bar makes no calls.
  function syncLive() {
    const s = state.sending ? section(state.sending.section) : activeSection();
    const want = !!(s && s.hasList && (
      (state.rows[s.id] || []).some((r) => r.live) || (state.sending && state.sending.section === s.id)));
    if (state.liveTimer && (!want || state.liveFor !== s.id)) {
      clearInterval(state.liveTimer);
      state.liveTimer = null; state.liveFor = null;
    }
    if (want && !state.liveTimer) {
      const every = Math.max(3, Number(s.live) || 5) * 1000;
      state.liveFor = s.id;
      state.liveTimer = setInterval(() => {
        if (!state.loading[s.id]) bridge.send({ type: "open", section: s.id });
      }, every);
    }
  }

  function renderPill() {
    $("#grip").innerHTML = icons.grip;
    $("#close").innerHTML = icons.close;
    $("#close").title = `Hide Maestro${state.hotkey ? " (" + state.hotkey + ")" : ""}`;

    // Idle, the strip says nothing at all; it is a sidebar, not a dashboard.
    const r = state.recording;
    const st = $("#status");
    st.className = "status" + (r.active ? " live" : "");
    if (r.active) {
      st.innerHTML = `<span class="wave"><i></i><i></i><i></i><i></i><i></i></span><span class="timer">${esc(r.elapsed || "0:00")}</span>`;
      st.title = r.mode === "screen" ? "Recording the screen and audio" : "Recording audio";
    } else {
      st.innerHTML = "";
      st.title = "";
    }

    const acts = $("#pillActions");
    acts.innerHTML = "";
    // Above the recorders on purpose: a screenshot is the cheapest thing on
    // the strip — no permission, no waiting, no watching yourself talk — and
    // it is the only one that can report something already gone.
    if (state.snip) {
      const b = el("button", "pbtn");
      b.title = "Screenshot a region" + (state.snipHint ? " — " + state.snipHint : "");
      b.setAttribute("aria-label", b.title);
      b.innerHTML = icons.camera;
      // Grab first, ask after: the crosshair appears the moment the camera is
      // pressed, and the words are asked for once there is a picture to
      // describe. Never feedback from here — this camera used to borrow the
      // open card's session, so a screenshot taken while merely LOOKING at a
      // card became a comment on it. Feedback is only what the Feedback
      // button starts.
      b.onclick = () => snip("region", "");
      acts.appendChild(b);
      // The whole screen, no drag: for "everything is wrong" and for the
      // things a region cannot hold — a layout, a dialog behind a dialog.
      const f = el("button", "pbtn");
      f.title = "Screenshot the whole screen";
      f.setAttribute("aria-label", f.title);
      f.innerHTML = icons.fullscreen;
      f.onclick = () => snip("full", "");
      acts.appendChild(f);
    }
    for (const rec of state.records) {
      const b = el("button", "pbtn rec");
      const live = r.active && r.mode === rec.mode;
      if (live) b.classList.add("live");
      b.title = live ? "Stop recording" : rec.label;
      b.setAttribute("aria-label", b.title);
      b.innerHTML = `<span class="ico-rec">${rec.mode === "screen" ? icons.screen : icons.mic}</span><span class="ico-stop">${icons.stop}</span>`;
      b.onclick = () => bridge.send({ type: "record", mode: rec.mode });
      acts.appendChild(b);
    }
    // The chevron points at the panel: towards where it will appear, and back
    // at the strip when it is already there. Not drawn at all for someone the
    // panel is not for; the strip above is the whole bar for them.
    if (!panelAllowed()) return;
    const waiting = Object.values(state.counts).reduce((a, n) => a + (n || 0), 0);
    const inward = state.edge === "left" ? icons.chevR : icons.chevL;
    const outward = state.edge === "left" ? icons.chevL : icons.chevR;
    const tog = el("button", "pbtn toggle");
    tog.innerHTML = `${state.collapsed ? inward : outward}${state.collapsed && waiting ? `<span class="badge">${waiting}</span>` : ""}`;
    tog.title = state.collapsed
      ? (waiting ? `Open the panel — ${waiting} waiting` : "Open the panel")
      : "Close the panel";
    tog.onclick = () => setCollapsed(!state.collapsed);
    acts.appendChild(tog);
  }

  function renderChips() {
    const c = $("#chips");
    c.innerHTML = "";
    if (state.askUrl) return;      // one question at a time
    const items = state.sections.map((s) => ({ id: s.id, title: s.title, icon: symbolIcon(s.symbol), n: s.hasList ? state.counts[s.id] || 0 : 0 }));
    if (state.ask) items.push({ id: ASK, title: "Ask", icon: icons.spark, n: 0 });
    c.classList.toggle("many", items.length > 4);
    items.forEach((it, i) => {
      if (i > 0) c.appendChild(el("span", "sep"));
      const b = el("button", "chip" + (state.active === it.id ? " on" : ""));
      b.innerHTML = `<span class="ico">${it.icon}</span><span>${esc(it.title)}</span>${it.n ? `<span class="n">${it.n}</span>` : ""}`;
      b.title = it.id === ASK ? "Ask the company brain" : it.title;
      b.onclick = () => setActive(it.id);
      c.appendChild(b);
    });
  }

  function renderContent() {
    const box = $("#scroll");
    box.innerHTML = "";
    if (state.askUrl) {
      // A screenshot asks a different question from a recording. The picture
      // already says WHERE; what it cannot say is what is wrong with it, and
      // those words are the whole ask — so they are asked for the same way,
      // with the same Skip, rather than being typed into a box that happens to
      // be on screen.
      box.appendChild(state.askUrl.kind === "snip"
        ? emptyState("What is wrong?",
            "Say what to look at in the picture, or skip it. It is sent either way.")
        : emptyState("Where is this?",
            "Paste the address of the page you are recording, or skip it. The recording starts either way."));
      return measure();
    }
    if (state.active === ASK) return renderThread(box);
    const s = activeSection();
    if (!s) { box.appendChild(emptyState("Nothing to show", "Add a section to bar.json and reload the config.")); return measure(); }
    if (s.hasList) renderCard(box, s); else renderCaptures(box, s);
    measure();
  }

  function emptyState(title, sub) {
    const e = el("div", "empty");
    e.innerHTML = `<div class="t">${esc(title)}</div>${sub ? `<div class="s">${esc(sub)}</div>` : ""}`;
    return e;
  }

  function renderCard(box, s) {
    const rows = state.rows[s.id];
    if (state.loading[s.id] || rows === undefined) {
      box.appendChild(el("div", "skeleton", "<i style='width:62%'></i><i style='width:38%'></i><i style='width:92%'></i><i style='width:84%'></i>"));
      return;
    }
    if (state.sending && state.sending.section === s.id) {
      const b = el("div", "sending");
      b.innerHTML = `<span class="pulse"></span><span>Sending your recording. The plan shows up here once it has been read.</span>`;
      box.appendChild(b);
    }
    if (!rows.length) {
      if (state.sending && state.sending.section === s.id) return;
      if (s.watch) box.appendChild(emptyState("Say what you want made", "Press record, describe the storyboards or the changes, stop. What was understood, what it costs and how long it takes show up here."));
      else box.appendChild(emptyState("Nothing waiting", state.api ? "New cards land here when the agent has something for you." : "No API is configured in bar.json."));
      return;
    }
    const i = state.index[s.id] || 0;
    const row = rows[i];
    const head = el("div", "card-head");
    head.innerHTML = `<span class="crumb">${esc(s.title)}</span>`;
    const nav = el("div", "nav");
    const prev = el("button", "", icons.chevL); prev.title = "Previous"; prev.disabled = i === 0;
    const next = el("button", "", icons.chevR); next.title = "Next"; next.disabled = i >= rows.length - 1;
    prev.onclick = () => step(-1); next.onclick = () => step(1);
    nav.appendChild(prev); nav.appendChild(el("span", "", `${i + 1} of ${rows.length}`)); nav.appendChild(next);
    head.appendChild(nav);
    box.appendChild(head);

    const card = el("div", "card" + (row.status ? " st-" + esc(row.status) : ""));
    let html = `<div class="c-title">${esc(row.title || "Untitled")}</div>`;
    if (row.subtitle) html += `<div class="c-sub">${esc(row.subtitle)}</div>`;
    if (typeof row.progress === "number") {
      // A run in progress. The bar is the truth as of the last poll; the
      // words under it say what is happening and how long is left.
      const pct = Math.round(Math.max(0.02, Math.min(1, row.progress)) * 100);
      html += `<div class="c-prog${row.status === "reading" ? " indeterminate" : ""}"><i style="width:${pct}%"></i></div>`;
      if (row.eta) html += `<div class="c-eta">${esc(row.eta)}</div>`;
    }
    if (row.body) html += `<div class="c-body">${esc(row.body)}</div>`;
    if (row.steps && row.steps.length) {
      html += `<ul class="c-steps">` + row.steps.map((st) =>
        `<li class="${esc(st.state || "pending")}"><i></i><span class="l">${esc(st.label)}</span>` +
        (st.note ? `<span class="n">${esc(st.note)}</span>` : "") +
        (st.url ? `<button class="lnk" data-url="${esc(st.url)}" title="Open">${icons.external}</button>` : "") +
        `</li>`).join("") + `</ul>`;
    }
    card.innerHTML = html;
    card.querySelectorAll(".lnk").forEach((b) => { b.onclick = () => bridge.send({ type: "open_url", url: b.dataset.url }); });
    box.appendChild(card);

    // Which buttons: the section's, unless the card says which of them apply.
    const allowed = Array.isArray(row.actions) ? new Set(row.actions) : null;
    const acts = el("div", "acts");
    (s.actions || []).forEach((a, k) => {
      if (allowed && !allowed.has(k)) return;
      const b = el("button", "act" + (k === 0 ? " primary" : ""));
      b.innerHTML = `${k === 0 ? icons.check : ""}<span>${esc(a.label)}</span>`;
      b.onclick = () => perform(s, k);
      acts.appendChild(b);
    });
    if (row.url) {
      const b = el("button", "act");
      b.innerHTML = `${icons.external}<span>Open</span>`;
      b.title = row.url;
      b.onclick = () => bridge.send({ type: "open_url", url: row.url });
      acts.appendChild(b);
    }
    // Say what is wrong with THIS branch, out loud. A section opts in with
    // "feedback": true, because only a card that stands for work in progress
    // has something to be given feedback ON.
    if (s.feedback) {
      const b = el("button", "act");
      b.innerHTML = `${icons.mic}<span>Feedback</span>`;
      b.title = "Record feedback on this session";
      b.onclick = () => {
        // Two ways to say it, and the difference matters: a screen recording
        // carries what you are pointing AT, which is most of what "this is
        // wrong" means. So it is asked rather than assumed.
        if (b.dataset.open) { closeChoice(); return; }
        const menu = el("div", "fb-choice");
        // Three ways, and every one of them is the ONLY way a session gets
        // feedback: the camera on the strip never attaches one.
        [["audio", icons.mic, "Just talk"],
         ["screen", icons.screen, "Show me"],
         ...(state.snip ? [["snip", icons.camera, "Snapshot"]] : [])].forEach(([mode, ico, label]) => {
          const c = el("button", "fb-opt", `${ico}<span>${label}</span>`);
          c.onclick = (ev) => {
            ev.stopPropagation();
            closeChoice();
            if (mode === "snip") snip("region", row.id);
            else bridge.send({ type: "record", mode, session: row.id });
          };
          menu.appendChild(c);
        });
        acts.appendChild(menu);
        b.dataset.open = "1";
        function closeChoice() {
          menu.remove();
          delete b.dataset.open;
          document.removeEventListener("click", away, true);
        }
        function away(ev) { if (!menu.contains(ev.target) && ev.target !== b) closeChoice(); }
        setTimeout(() => document.addEventListener("click", away, true), 0);
      };
      acts.appendChild(b);
    }
    if (acts.childElementCount) box.appendChild(acts);
  }

  function renderCaptures(box, s) {
    if (!state.captures.length) {
      box.appendChild(emptyState("Capture an idea before it evaporates", "Type it, or hold the microphone. Each one is kept with the time it was said."));
      return;
    }
    const list = el("div", "captures");
    for (const c of state.captures) {
      const r = el("div", "capture");
      r.innerHTML = `<span class="when">${esc(c.when)}</span><span class="what">${esc(c.text)}</span>`;
      list.appendChild(r);
    }
    box.appendChild(list);
  }

  function renderThread(box) {
    if (!state.thread.length && !state.busy) {
      box.appendChild(emptyState("Ask the company brain", "Clients, meetings, decisions — what was said, by whom, and when. Answers cite their sources."));
      return measure();
    }
    const t = el("div", "thread");
    for (const m of state.thread) {
      if (m.role === "user") {
        const w = el("div", "msg-user");
        w.appendChild(el("div", "bubble", esc(m.text)));
        t.appendChild(w);
      } else {
        const w = el("div", "msg-ai");
        w.appendChild(el("div", "answer" + (m.error ? " error" : ""), esc(m.text)));
        if (m.citations && m.citations.length) {
          const c = el("div", "cites");
          for (const cit of m.citations.slice(0, 6)) {
            const b = el("button", "cite");
            b.innerHTML = `<b>${esc(cit.n)}</b><span>${esc(cit.title || cit.source || "source")}</span>${cit.url ? icons.external : ""}`;
            b.title = cit.url || cit.source || "";
            b.onclick = () => { if (cit.url) bridge.send({ type: "open_url", url: cit.url }); };
            c.appendChild(b);
          }
          w.appendChild(c);
        }
        if (!m.error) {
          const u = el("div", "under");
          const cp = el("button", "", `${icons.copy}<span>Copy</span>`);
          cp.onclick = () => { bridge.send({ type: "copy", text: m.text }); toast("Copied"); };
          u.appendChild(cp);
          w.appendChild(u);
        }
        t.appendChild(w);
      }
    }
    if (state.busy) t.appendChild(el("div", "thinking", "<i></i><i></i><i></i>"));
    box.appendChild(t);
    box.scrollTop = box.scrollHeight;
    measure();
  }

  function renderComposer() {
    if (state.askUrl) return renderUrlComposer();
    const s = activeSection();
    const ph = $("#ph");
    const canType = state.active === ASK || !!(s && s.compose);
    let text;
    if (state.active === ASK) text = (state.ask && state.ask.placeholder) || "Ask about clients, meetings, decisions";
    else if (s && s.compose) text = s.compose.placeholder || "Start typing";
    else text = s && s.hasList ? "Nothing to type here. Use the buttons above." : "Nothing to type here";
    // The send hint only where there is something to send. "Nothing to type
    // here, or press send" was the box contradicting itself.
    ph.innerHTML = canType
      ? `<span>${esc(text)}, or</span><kbd>${modKey()}</kbd><kbd>↵</kbd><span>to send</span>`
      : `<span>${esc(text)}</span>`;
    ph.hidden = $("#input").value.length > 0;
    $("#input").disabled = !canType;
    $("#send").disabled = !canType;
    $("#send").innerHTML = icons.send;
    renderTools();
  }

  /// Take a screenshot now — a region to drag, or the whole screen — and let
  /// the native side come back with `snip_taken`, which is when the box asks
  /// what it shows. With a session the picture is feedback on that session;
  /// without one it is a plain screenshot. Only the Feedback button ever
  /// passes a session.
  function snip(mode, session) {
    if (state.askUrl) return;               // one question at a time
    bridge.send({ type: "snip", mode, session: session || "" });
  }

  /// The picture is on disk but nobody wants it after all.
  function discardSnip() {
    state.askUrl = null;
    $("#input").value = "";
    autosize();
    bridge.send({ type: "snip_discard" });
    render();
    setCollapsed(true);
  }

  /// The box, while it is asking where a recording is: an address to paste,
  /// Send to record with it and Skip to record without.
  function renderUrlComposer() {
    // One question, asked the same way before a recording and after a
    // screenshot: a link to the page, what is wrong, or both in one line.
    // The native side pulls the link out and keeps the rest as the note, so
    // nobody has to know there are two fields. The answer is optional in
    // both and pressing on regardless is the point, hence the same Skip.
    const snip = state.askUrl && state.askUrl.kind === "snip";
    const ph = $("#ph");
    ph.innerHTML = `<span>Paste a link, say what is wrong — or both</span>`;
    ph.hidden = $("#input").value.length > 0;
    $("#input").disabled = false;
    $("#send").disabled = false;
    $("#send").innerHTML = icons.send;
    $("#send").title = snip ? "Send the screenshot" : "Start recording";
    const left = $("#toolsLeft");
    left.innerHTML = "";
    const skip = el("button", "tool", "<span>Skip</span>");
    skip.title = snip ? "Send without a note" : "Record without a note";
    skip.onclick = () => answerUrl("");
    left.appendChild(skip);
    if (snip) {
      // The shot already exists, so "never mind" needs its own button; before
      // this, cancelling was Esc on the crosshair, which is now behind us.
      const d = el("button", "tool", "<span>Discard</span>");
      d.title = "Throw the screenshot away";
      d.onclick = discardSnip;
      left.appendChild(d);
    }
  }

  function renderTools() {
    const s = activeSection();
    const left = $("#toolsLeft");
    left.innerHTML = "";
    const r = state.recording;
    const wantsMic = !!(s && s.compose && s.compose.record) && state.records.some((x) => x.mode === "audio");
    if (wantsMic) {
      const live = r.active && r.mode === "audio";
      const b = el("button", "tool" + (live ? " live" : ""));
      b.innerHTML = live ? `${icons.stop}<span class="timer">${esc(r.elapsed || "0:00")}</span>` : `${icons.mic}<span>Voice</span>`;
      b.title = live ? "Stop recording" : "Record audio";
      b.onclick = () => bridge.send({ type: "record", mode: "audio" });
      left.appendChild(b);
    }
    if (state.active !== ASK && s && s.hasList && s.compose) {
      const row = current();
      left.appendChild(el("span", "hint", row ? "About this card" : "Open a card first"));
    }
  }

  // ---- actions ------------------------------------------------------------
  function step(d) {
    const s = activeSection();
    if (!s) return;
    const rows = state.rows[s.id] || [];
    state.index[s.id] = Math.max(0, Math.min(rows.length - 1, (state.index[s.id] || 0) + d));
    renderContent(); renderTools();
  }

  function perform(s, k) {
    const row = current();
    if (!row) return;
    bridge.send({ type: "action", section: s.id, index: k, id: row.id });
    const a = (s.actions || [])[k] || {};
    if (a.advance === false) {
      // The card stays — Go starts a run and the card is where it is
      // watched. It reads as started at once and the truth follows.
      row.status = "running"; row.live = true; row.actions = [];
      row.subtitle = "starting"; row.progress = 0.02; row.eta = "";
      renderContent(); renderTools(); syncLive();
      setTimeout(() => bridge.send({ type: "open", section: s.id }), 900);
      return;
    }
    // Optimistic: the card leaves at once. A failure reloads the list from
    // the native side, which arrives as a fresh `rows` message.
    const rows = state.rows[s.id] || [];
    const i = state.index[s.id] || 0;
    rows.splice(i, 1);
    state.index[s.id] = Math.min(i, Math.max(0, rows.length - 1));
    state.counts[s.id] = rows.length;
    renderContent(); renderChips(); renderTools();
  }

  /// Send and Skip both go ahead; only one of them carries anything. Either
  /// way the panel closes, because answering was the only reason it was open.
  function answerUrl(text) {
    const ask = state.askUrl || {};
    state.askUrl = null;
    $("#input").value = "";
    autosize();
    // The same line either way: a link, words, or both. The native side
    // splits it; the page does not know or care which parts are in it.
    if (ask.kind === "snip") {
      // The screenshot is already on disk; the native side kept it and the
      // session it belongs to. Only the words travel now.
      bridge.send({ type: "snip_note", text });
    } else {
      bridge.send({ type: "url_answer", text, mode: ask.mode || "audio" });
    }
    render();
    setCollapsed(true);
  }

  function send() {
    const input = $("#input");
    const text = input.value.trim();
    if (state.askUrl) { answerUrl(text); return; }
    if (!text) return;
    if (state.active === ASK) {
      if (state.busy) return;
      state.thread.push({ role: "user", text });
      state.busy = true;
      bridge.send({ type: "ask", text });
    } else {
      const s = activeSection();
      if (!s || !s.compose) return;
      const row = current();
      if (s.hasList && !row) { toast("Open a card first"); return; }
      bridge.send({ type: "compose", section: s.id, text, id: row ? row.id : null });
      if (!s.hasList) state.captures.unshift({ text, when: timeShort(new Date()) });
    }
    input.value = "";
    autosize();
    renderContent(); renderComposer();
  }

  function autosize() {
    const input = $("#input");
    input.style.height = "auto";
    input.style.height = Math.min(96, input.scrollHeight) + "px";
    $("#ph").hidden = input.value.length > 0;
    measure();
  }

  // ---- size and drag: the native window follows the content ---------------
  let lastH = 0, lastW = 0, lastC = 0;
  function measure() {
    // Folded, the panel is out of the flow, so this is the strip and nothing
    // more — which is exactly the area the window is allowed to cover.
    //
    // `centre` is how far down the strip's own middle sits. The window is
    // anchored by that rather than by its top, so the strip stays level with
    // the middle of the screen whatever height the panel happens to be.
    const root = $("#root");
    const bar = $("#barRow");
    const h = root.offsetHeight;
    const w = root.offsetWidth;
    const c = Math.round(bar.offsetTop + bar.offsetHeight / 2);
    if (h !== lastH || w !== lastW || c !== lastC) {
      lastH = h; lastW = w; lastC = c;
      bridge.send({ type: "size", width: w, height: h, centre: c });
    }
  }
  new ResizeObserver(() => measure()).observe(document.body);

  function bindDrag(node) {
    node.addEventListener("mousedown", (e) => {
      if (e.button !== 0) return;
      if (e.target.closest("button:not(.grip), textarea, a")) return;
      bridge.send({ type: "drag" });
    });
  }

  // ---- wire up --------------------------------------------------------------
  function init() {
    bindDrag($("#grip"));
    bindDrag($("#pill"));
    $("#close").onclick = () => bridge.send({ type: "hide" });
    $("#send").onclick = send;
    const input = $("#input");
    input.addEventListener("input", autosize);
    input.addEventListener("focus", () => bridge.send({ type: "focus" }));
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); }
      else if (e.key === "Escape") { e.preventDefault(); onEscape(); }
    });
    document.addEventListener("keydown", (e) => {
      if (e.target === input) return;
      if (e.key === "Escape") onEscape();
      else if (e.key === "ArrowLeft" && (e.metaKey || e.ctrlKey)) step(-1);
      else if (e.key === "ArrowRight" && (e.metaKey || e.ctrlKey)) step(1);
    });
    // typing anywhere in the panel goes to the box
    $("#panel").addEventListener("mousedown", (e) => { if (!e.target.closest("button, a, .c-body, .answer, .bubble")) setTimeout(() => input.focus(), 0); });
    setCollapsed(state.collapsed);
    render();
    bridge.send({ type: "ready" });
  }

  if (window.qt && window.qt.webChannelTransport && window.QWebChannel) {
    new window.QWebChannel(window.qt.webChannelTransport, (ch) => {
      window.__qt = ch.objects.maestro;
      window.__qt.toWeb.connect((s) => window.maestro.receive(s));
      init();
    });
  } else if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
