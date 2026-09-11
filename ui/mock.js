/* A pretend native side, for looking at the bar in a browser:
 *   open ui/preview.html, then ?mock=empty or ?mock=recording in the address bar
 * Nothing here ships in the app. */
(() => {
  const q = new URLSearchParams(location.search);
  if (!q.has("mock")) return;
  const scenario = q.get("mock") || "";
  const send = (m) => setTimeout(() => window.maestro.receive(m), 0);
  let rec = { active: false, mode: "", elapsed: "" }, t0 = 0, tick = null;
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
  window.__mock = (m) => {
    switch (m.type) {
      case "ready":
        send({ type: "state", platform: q.get("os") === "win" ? "win" : "mac", hotkey: "⌘M", api: true,
          edge: q.get("edge") === "left" ? "left" : "right",
          sections: [
            { id: "review", title: "Review", symbol: "tray.full", hasList: true,
              actions: [{ label: "Done" }, { label: "Dismiss" }, { label: "Send the email" }],
              compose: { placeholder: "Tell the agent what to change", record: false } },
            { id: "board", title: "Board", symbol: "board", hasList: true,
              actions: [{ label: "Keep" }, { label: "Undo all" }], compose: null },
            { id: "capture", title: "Capture", symbol: "square.and.pencil", hasList: false, actions: [],
              compose: { placeholder: "Idea, decision, ticket", record: true } },
          ],
          records: [{ mode: "audio", label: "Record audio" }, { mode: "screen", label: "Record screen and audio" }],
          ask: { placeholder: "Ask about clients, meetings, decisions" },
          counts: { review: rows.length, board: boardRows.length }, recording: rec });
        if (scenario === "recording") setTimeout(() => window.__mock({ type: "record", mode: "audio" }), 50);
        // The app never opens the panel by itself, and neither does this.
        if (scenario === "open") send({ type: "expand" });
        break;
      case "open": setTimeout(() => send({ type: "rows", section: m.section, rows: (m.section === "board" ? boardRows : rows).slice() }), 350); break;
      case "ask":
        setTimeout(() => send({ type: "answer",
          text: "Kupola Media asked for a two-day shoot in Ohrid with a drone unit [1]. Marko confirmed the 12th and 13th are open on their side [2], and the last quote sent was 4,800 EUR excluding travel [3].",
          citations: [{ n: 1, source: "gmail", title: "Re: Ohrid shoot — quote v2", url: "https://mail.google.com" }, { n: 2, source: "meeting", title: "Call with Marko, 3 Sep", url: "" }, { n: 3, source: "slack", title: "#sales · quote thread", url: "https://slack.com" }] }), 1100);
        break;
      case "record":
        if (rec.active) { rec = { active: false, mode: "", elapsed: "" }; clearInterval(tick); send({ type: "recording", ...rec }); send({ type: "toast", text: "Saved 2026-09-10-14-05.m4a, processing now" }); }
        else { rec = { active: true, mode: m.mode, elapsed: "0:00" }; t0 = Date.now() - (scenario === "recording" ? 84000 : 0); send({ type: "recording", ...rec });
          tick = setInterval(() => { const s = Math.floor((Date.now() - t0) / 1000); rec.elapsed = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; send({ type: "recording", ...rec }); }, 1000); }
        break;
      case "action": send({ type: "toast", text: (m.section === "board" ? ["Kept", "Undone on Trello"] : ["Marked done", "Dismissed", "Sent"])[m.index] || "Done" }); break;
      case "compose": send({ type: "toast", text: m.section === "capture" ? "Captured" : "Instruction sent" }); break;
      case "size": document.title = `Maestro Bar ${m.width}×${m.height}`; break;
      case "hide": document.body.style.opacity = "0.15"; setTimeout(() => (document.body.style.opacity = ""), 600); break;
      default: break;
    }
  };
})();
