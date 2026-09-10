/* Maestro Bar — the interface, shared by the macOS and Windows apps.
 *
 * The native side owns the window, the token, the recorder and every HTTP
 * call. This file owns what is on screen. The two talk in small JSON messages:
 *
 *   web → native   ready · open · action · compose · ask · record · hide ·
 *                  drag · size · focus · open_url · copy
 *   native → web   state · rows · counts · recording · toast · answer ·
 *                  answer_error · escape
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
    spark: I('<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 16l.8 2.2L22 19l-2.2.8L19 22l-.8-2.2L16 19l2.2-.8z"/>'),
    check: I('<path d="M5 12.5l4.5 4.5L19 7"/>'),
    send: I('<path d="M12 19V5M6 11l6-6 6 6"/>'),
    copy: I('<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a1 1 0 011-1h10"/>'),
    link: I('<path d="M14 4h6v6M20 4l-9 9M18 13v6a1 1 0 01-1 1H5a1 1 0 01-1-1V7a1 1 0 011-1h6"/>'),
    external: I('<path d="M14 4h6v6M20 4l-9 9"/>'),
    logo: '<svg width="24" height="24" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="10" stroke="currentColor" stroke-width="1.8"/><path d="M7.5 16V8.5l4.5 5 4.5-5V16" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  };
  // SF Symbol names in bar.json → the drawn set. Unknown names get a spark.
  const symbolIcon = (name = "") => {
    const n = name.toLowerCase();
    if (n.includes("tray") || n.includes("inbox")) return icons.inbox;
    if (n.includes("pencil") || n.includes("square.and")) return icons.pencil;
    if (n.includes("mic")) return icons.mic;
    if (n.includes("display") || n.includes("rectangle")) return icons.screen;
    if (n.includes("record")) return icons.mic;
    if (n.includes("check")) return icons.check;
    return icons.spark;
  };

  // ---- state ------------------------------------------------------------
  const ASK = "ask";
  const state = {
    platform: "mac",
    hotkey: "",
    api: true,
    sections: [],          // [{id,title,symbol,hasList,actions:[{label,symbol}],compose:{placeholder,record}|null}]
    records: [],           // [{mode,label}]
    ask: null,             // {placeholder} when the brain can be asked
    recording: { active: false, mode: "", elapsed: "" },
    counts: {},
    active: null,          // section id, or ASK
    rows: {},              // section id → [{id,title,subtitle,body}]
    index: {},             // section id → current card
    loading: {},           // section id → true while the list is on its way
    thread: [],            // ask: [{role:'user'|'assistant', text, citations, error}]
    captures: [],          // this session's captures, newest first
    busy: false,           // an ask is in flight
    collapsed: false,
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
        state.hotkey = m.hotkey || "";
        state.api = m.api !== false;
        state.sections = m.sections || [];
        state.records = m.records || [];
        state.ask = m.ask || null;
        state.counts = m.counts || {};
        if (m.recording) state.recording = m.recording;
        const ids = state.sections.map((s) => s.id);
        if (!state.active || (state.active !== ASK && !ids.includes(state.active))) {
          state.active = ids[0] || (state.ask ? ASK : null);
        }
        render();
        loadActive();
        break;
      }
      case "rows": {
        state.rows[m.section] = m.rows || [];
        state.index[m.section] = 0;
        state.loading[m.section] = false;
        state.counts[m.section] = (m.rows || []).length;
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
      case "escape": onEscape(); break;
      case "expand": setCollapsed(false); break;
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

  function loadActive() {
    const s = activeSection();
    if (!s || !s.hasList) return;
    if (state.rows[s.id] === undefined && !state.loading[s.id]) {
      state.loading[s.id] = true;
      bridge.send({ type: "open", section: s.id });
      renderContent();
    }
  }

  function setActive(id) {
    state.active = id;
    setCollapsed(false);
    render();
    loadActive();
    $("#input").focus();
  }

  function setCollapsed(v) {
    state.collapsed = v;
    $("#panel").classList.toggle("collapsed", v);
    renderPill();
    measure();
    if (!v) setTimeout(() => $("#input").focus(), 30);
  }

  function onEscape() {
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
  function render() { renderPill(); renderContent(); renderChips(); renderComposer(); measure(); }

  function renderPill() {
    $("#grip").innerHTML = icons.grip;
    $("#close").innerHTML = icons.close;
    $("#close").title = `Hide Maestro${state.hotkey ? " (" + state.hotkey + ")" : ""}`;
    $("#logo").innerHTML = icons.logo;

    const r = state.recording;
    const st = $("#status");
    st.className = "status" + (r.active ? " live" : "");
    if (r.active) {
      st.innerHTML = `<span class="dot"></span><span class="wave"><i></i><i></i><i></i><i></i><i></i></span><span class="timer">${esc(r.elapsed || "0:00")}</span>`;
      st.title = r.mode === "screen" ? "Recording the screen and audio" : "Recording audio";
    } else {
      st.innerHTML = `<span class="dot"></span><span>Not recording</span>`;
      st.title = "";
    }

    const acts = $("#pillActions");
    acts.innerHTML = "";
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
    const waiting = Object.values(state.counts).reduce((a, n) => a + (n || 0), 0);
    const tog = el("button", "pbtn label");
    tog.innerHTML = `<span class="chev">${state.collapsed ? icons.chevDown : icons.chevUp}</span><span>${state.collapsed ? "Show" : "Hide"}</span>${state.collapsed && waiting ? `<span class="badge">${waiting}</span>` : ""}`;
    tog.title = state.collapsed ? "Show the panel" : "Hide the panel";
    tog.onclick = () => setCollapsed(!state.collapsed);
    acts.appendChild(tog);
  }

  function renderChips() {
    const c = $("#chips");
    c.innerHTML = "";
    const items = state.sections.map((s) => ({ id: s.id, title: s.title, icon: symbolIcon(s.symbol), n: s.hasList ? state.counts[s.id] || 0 : 0 }));
    if (state.ask) items.push({ id: ASK, title: "Ask", icon: icons.spark, n: 0 });
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
    if (!rows.length) {
      box.appendChild(emptyState("Nothing waiting", state.api ? "New cards land here when the agent has something for you." : "No API is configured in bar.json."));
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

    const card = el("div", "card");
    card.innerHTML = `<div class="c-title">${esc(row.title || "Untitled")}</div>${row.subtitle ? `<div class="c-sub">${esc(row.subtitle)}</div>` : ""}${row.body ? `<div class="c-body">${esc(row.body)}</div>` : ""}`;
    box.appendChild(card);

    if (s.actions && s.actions.length) {
      const acts = el("div", "acts");
      s.actions.forEach((a, k) => {
        const b = el("button", "act" + (k === 0 ? " primary" : ""));
        b.innerHTML = `${k === 0 ? icons.check : ""}<span>${esc(a.label)}</span>`;
        b.onclick = () => perform(s, k);
        acts.appendChild(b);
      });
      box.appendChild(acts);
    }
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
    const s = activeSection();
    const ph = $("#ph");
    let text;
    if (state.active === ASK) text = (state.ask && state.ask.placeholder) || "Ask about clients, meetings, decisions";
    else if (s && s.compose) text = s.compose.placeholder || "Start typing";
    else text = "Nothing to type here";
    ph.innerHTML = `<span>${esc(text)}, or</span><kbd>${modKey()}</kbd><kbd>↵</kbd><span>to send</span>`;
    ph.hidden = $("#input").value.length > 0;
    const canType = state.active === ASK || !!(s && s.compose);
    $("#input").disabled = !canType;
    $("#send").disabled = !canType;
    $("#send").innerHTML = icons.send;
    renderTools();
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
    // Optimistic: the card leaves at once. A failure reloads the list from
    // the native side, which arrives as a fresh `rows` message.
    const rows = state.rows[s.id] || [];
    const i = state.index[s.id] || 0;
    rows.splice(i, 1);
    state.index[s.id] = Math.min(i, Math.max(0, rows.length - 1));
    state.counts[s.id] = rows.length;
    renderContent(); renderChips(); renderTools();
  }

  function send() {
    const input = $("#input");
    const text = input.value.trim();
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
  let lastH = 0, lastW = 0;
  function measure() {
    const root = $("#root");
    const h = state.collapsed ? $("#barRow").offsetHeight + 40 : root.offsetHeight;
    const w = root.offsetWidth;
    if (h !== lastH || w !== lastW) {
      lastH = h; lastW = w;
      bridge.send({ type: "size", width: w, height: h });
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
    $("#logo").onclick = () => bridge.send({ type: "open_url", url: "" });
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
