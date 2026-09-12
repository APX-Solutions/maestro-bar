/* A pretend native side, for looking at the bar in a browser:
 *   open ui/preview.html, then ?mock=empty or ?mock=recording in the address bar
 * Nothing here ships in the app. */
(() => {
  const q = new URLSearchParams(location.search);
  if (!q.has("mock")) return;
  const scenario = q.get("mock") || "";
  const send = (m) => setTimeout(() => window.maestro.receive(m), 0);
  let rec = { active: false, mode: "", elapsed: "" }, t0 = 0, tick = null, pending = "";
  const rows = scenario === "empty" ? [] : [
    { id: "a1", title: "Follow up on the Ohrid shoot", subtitle: "Kupola Media", body: "Hi Marko, thanks for the call this morning. As discussed, here is the revised quote for the two-day shoot in Ohrid with the drone unit included. The dates you asked about are open on our side." },
    { id: "a2", title: "Send the proposal to Tamara", subtitle: "Visible", body: "Attach the GEO framework deck and the scoring methodology. She asked for it by Thursday." },
    { id: "a3", title: "Confirm the studio booking", subtitle: "Carbon Box", body: "Studio B is on hold for the 18th. Reply to confirm or release it." },
  ];
  const boardRows = scenario === "empty" ? [] : [
    { id: "b1", title: "Katalyst and Sofi health go to Tina, two new sample tasks",
      subtitle: "AI UGC ADS, 5 changes, 14:05",
      body: "Moved “Katalyst” to TINA TASKS\nAssigned “Katalyst” to Tina Trajkovska\nMoved “Sofi health” to TINA TASKS\nCreated “[Rentalz] 3 hook variations” in ALEKSEJ TASKS\nDue Fri 18 Sep on “[Rentalz] 3 hook variations”" },
  ];
  // Storyboards from voice: one card per state, so each can be looked at.
  const studioRows = scenario === "empty" ? [] : [
    { id: "s1", title: "3 storyboards for Witches Brew", subtitle: "≈ $8 · about 6 min · Go to start", status: "proposed", actions: [0, 2],
      steps: [{ label: "Kitchen morning, discovery box", state: "pending", note: "≈ $3.04" }, { label: "Premium studio, single tea", state: "pending", note: "≈ $3.04" }, { label: "Raw phone selfie, unboxing", state: "pending", note: "≈ $2.38" }] },
    { id: "s2", title: "2 storyboards for Kupola", subtitle: "1 of 2 done · drawing frames 3 of 6", status: "running", progress: 0.72, eta: "about 2 min left", live: true, actions: [2], url: "https://app.advertisable.ai/adflow/brands/b/j1/ugc/storyboard",
      steps: [{ label: "Drone over Ohrid at dawn", state: "done", url: "https://app.advertisable.ai/adflow/brands/b/j1/ugc/storyboard" }, { label: "Studio, the two-day package", state: "running", note: "drawing frames 3 of 6", url: "https://app.advertisable.ai/adflow/brands/b/j2/ugc/storyboard" }] },
    { id: "s3", title: "Redraw frames 2 and 5 of Discovery Journey", subtitle: "0 of 1 done · 1 failed", status: "failed", actions: [1, 2], body: "Redraw: the wallet is $1.20; nothing was spent",
      steps: [{ label: "Change: bigger box, no logo inside", state: "failed", note: "the wallet is $1.20" }] },
    { id: "s4", title: "Reading your recording", subtitle: "about a minute", status: "reading", progress: 0, eta: "listening and looking at what was on screen", live: true, actions: [], steps: [] },
  ];
  window.__mock = (m) => {
    switch (m.type) {
      case "ready":
        send({ type: "state", platform: q.get("os") === "win" ? "win" : "mac", hotkey: "⌘M", api: true,
          edge: q.get("edge") === "left" ? "left" : "right",
          sections: [
            { id: "board", title: "Board", symbol: "board", hasList: true,
              actions: [{ label: "Keep" }, { label: "Undo all" }], compose: null },
            { id: "storyboards", title: "Storyboards", symbol: "film", hasList: true, live: 5, watch: true,
              actions: [{ label: "Go", advance: false }, { label: "Retry", advance: false }, { label: "Dismiss" }],
              compose: { placeholder: "Change the plan, or ask for more", record: false } },
            { id: "capture", title: "Capture", symbol: "square.and.pencil", hasList: false, actions: [],
              compose: { placeholder: "Idea, decision, ticket", record: true } },
          ],
          records: [{ mode: "audio", label: "Record audio" }, { mode: "screen", label: "Record screen and audio" }],
          ask: { placeholder: "Ask about clients, meetings, decisions" },
          counts: { board: boardRows.length, storyboards: studioRows.length }, recording: rec });
        if (scenario === "sent") setTimeout(() => send({ type: "sent" }), 400);
        if (scenario === "recording") setTimeout(() => window.__mock({ type: "record", mode: "audio" }), 50);
        // The app never opens the panel by itself, and neither does this.
        if (scenario === "open") send({ type: "expand" });
        break;
      case "open": setTimeout(() => send({ type: "rows", section: m.section, rows: (m.section === "board" ? boardRows : m.section === "storyboards" ? studioRows : rows).slice() }), 350); break;
      case "ask":
        setTimeout(() => send({ type: "answer",
          text: "Kupola Media asked for a two-day shoot in Ohrid with a drone unit [1]. Marko confirmed the 12th and 13th are open on their side [2], and the last quote sent was 4,800 EUR excluding travel [3].",
          citations: [{ n: 1, source: "gmail", title: "Re: Ohrid shoot — quote v2", url: "https://mail.google.com" }, { n: 2, source: "meeting", title: "Call with Marko, 3 Sep", url: "" }, { n: 3, source: "slack", title: "#sales · quote thread", url: "https://slack.com" }] }), 1100);
        break;
      case "record":
        // The app asks where the recording is before it starts one, so this
        // does too.
        if (!rec.active) { pending = m.mode; send({ type: "ask_url", mode: m.mode, prefill: "https://trello.com/b/lK7A4EEE/ai-ugc-ads" }); break; }
        window.__mock({ type: "url_answer", url: "", mode: m.mode });
        break;
      case "url_answer":
        if (rec.active) { rec = { active: false, mode: "", elapsed: "" }; clearInterval(tick); send({ type: "recording", ...rec }); send({ type: "toast", text: "Saved 2026-09-10-14-05.m4a, processing now" }); }
        else { rec = { active: true, mode: m.mode || pending, elapsed: "0:00" }; t0 = Date.now() - (scenario === "recording" ? 84000 : 0); send({ type: "recording", ...rec });
          tick = setInterval(() => { const s = Math.floor((Date.now() - t0) / 1000); rec.elapsed = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; send({ type: "recording", ...rec }); }, 1000); }
        break;
      case "action": send({ type: "toast", text: (m.section === "board" ? ["Kept", "Undone on Trello"] : m.section === "storyboards" ? ["Started", "Retrying", "Dismissed"] : ["Marked done", "Dismissed", "Sent"])[m.index] || "Done" }); break;
      case "compose": send({ type: "toast", text: m.section === "capture" ? "Captured" : "Instruction sent" }); break;
      case "size": document.title = `Maestro Bar ${m.width}×${m.height}`; break;
      case "hide": document.body.style.opacity = "0.15"; setTimeout(() => (document.body.style.opacity = ""), 600); break;
      default: break;
    }
  };
})();
