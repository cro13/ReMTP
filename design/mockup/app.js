(() => {
  const P = new URLSearchParams(location.search);
  const SCREENS = [
    ["main", "Two panes"],
    ["transfers", "Transfers"],
    ["sync", "Sync"],
    ["inspector", "Inspector"],
    ["access", "Device access"],
    ["windows", "Windows"],
  ];
  const screen = SCREENS.some(([k]) => k === P.get("screen")) ? P.get("screen") : "main";
  const theme = P.get("theme") || (["inspector", "access"].includes(screen) ? "dark" : "light");
  const plat = screen === "windows" ? "win" : "mac";
  const shot = P.has("shot");
  if (theme === "dark") document.documentElement.classList.add("dark");
  if (plat === "win") document.documentElement.classList.add("pwin");
  const HOST = plat === "win" ? "PC" : "Mac";

  const I = {
    back: '<path d="M12.5 4.5 7 10l5.5 5.5"/>',
    fwd: '<path d="M7.5 4.5 13 10l-5.5 5.5"/>',
    chev: '<path d="M7.5 4 13.5 10l-6 6"/>',
    chevD: '<path d="M4.5 7.5 10 13l5.5-5.5"/>',
    chevU: '<path d="M4.5 12.5 10 7l5.5 5.5"/>',
    sidebarR: '<rect x="2.5" y="4" width="15" height="12" rx="2.5"/><path d="M12.5 4v12"/>',
    list: '<path d="M7.5 6h9M7.5 10h9M7.5 14h9"/><circle class="f" cx="4" cy="6" r="1.1"/><circle class="f" cx="4" cy="10" r="1.1"/><circle class="f" cx="4" cy="14" r="1.1"/>',
    columns: '<rect x="2.5" y="4" width="15" height="12" rx="2.5"/><path d="M7.5 4v12M12.5 4v12"/>',
    grid: '<rect x="3" y="3" width="5.5" height="5.5" rx="1.3"/><rect x="11.5" y="3" width="5.5" height="5.5" rx="1.3"/><rect x="3" y="11.5" width="5.5" height="5.5" rx="1.3"/><rect x="11.5" y="11.5" width="5.5" height="5.5" rx="1.3"/>',
    search: '<circle cx="8.5" cy="8.5" r="5"/><path d="m12.3 12.3 4.2 4.2"/>',
    folder: '<path d="M2.5 6.2c0-.9.7-1.7 1.6-1.7h3.5l1.7 1.8h6.6c.9 0 1.6.7 1.6 1.6v6.9c0 .9-.7 1.7-1.6 1.7H4.1c-.9 0-1.6-.8-1.6-1.7z"/>',
    note: '<path d="M8 14.5V5.2l8-1.7v9.3"/><circle cx="6" cy="14.5" r="2"/><circle cx="14" cy="12.8" r="2"/>',
    image: '<rect x="3" y="4" width="14" height="12" rx="2"/><circle cx="7.5" cy="8.3" r="1.4"/><path d="m3.5 14.5 4.2-3.8 3 2.6 2.3-2 3.5 3"/>',
    doc: '<path d="M6 2.5h5.5L15.5 6.5V16a1.5 1.5 0 0 1-1.5 1.5H6A1.5 1.5 0 0 1 4.5 16V4A1.5 1.5 0 0 1 6 2.5z"/><path d="M11.5 2.5v4h4M7.5 10.5h5M7.5 13.5h5"/>',
    archive: '<rect x="3.5" y="3" width="13" height="14" rx="2"/><path d="M10 3v1.6M10 6.2v1.6M10 9.4V11"/><rect x="8.7" y="12" width="2.6" height="2.8" rx=".7"/>',
    dap: '<rect x="5" y="2.5" width="10" height="15" rx="2.2"/><rect x="6.8" y="4.3" width="6.4" height="6.6" rx=".8"/><circle cx="10" cy="14.2" r="1.5"/><path d="M15 5.5h1.2v3H15"/>',
    phone: '<rect x="5.5" y="2.5" width="9" height="15" rx="2.2"/><path d="M8.8 4.6h2.4M8.8 15.3h2.4"/>',
    tablet: '<rect x="3" y="3" width="14" height="14" rx="2.2"/><path d="M8.8 15h2.4"/>',
    usbdev: '<rect x="5.5" y="8" width="9" height="9.5" rx="1.8"/><path d="M7.5 8V3h5v5"/><path d="M9 5.2h.01M11 5.2h.01"/>',
    chip: '<rect x="5" y="5" width="10" height="10" rx="1.8"/><path d="M8 2.5v2.5M12 2.5v2.5M8 15v2.5M12 15v2.5M2.5 8H5M2.5 12H5M15 8h2.5M15 12h2.5"/>',
    sd: '<path d="M7 2.5h6.3l3.2 3.2V16c0 .8-.7 1.5-1.5 1.5H7c-.8 0-1.5-.7-1.5-1.5V4c0-.8.7-1.5 1.5-1.5z"/><path d="M8.5 3v3M10.8 3v3M13.1 3.5V6"/>',
    sync: '<path d="M15.6 8.2A6 6 0 0 0 4.9 6.3M4.4 11.8a6 6 0 0 0 10.7 1.9"/><path d="M4.6 3.2v3.4H8M15.4 16.8v-3.4H12"/>',
    home: '<path d="M3.5 9 10 3.5 16.5 9M5.5 7.5v8.5h9V7.5"/><path d="M8.5 16v-4.5h3V16"/>',
    download: '<circle cx="10" cy="10" r="7"/><path d="M10 6.5v6.5M7.3 10.5 10 13.2l2.7-2.7"/>',
    desktop: '<rect x="2.5" y="3.5" width="15" height="10" rx="1.8"/><path d="M7.5 16.5h5M10 13.5v3"/>',
    eject: '<path d="M10 4.5 4.5 11h11z"/><path d="M4.5 14.5h11"/>',
    pause: '<path d="M7.5 5v10M12.5 5v10"/>',
    x: '<path d="m5.5 5.5 9 9M14.5 5.5l-9 9"/>',
    min: '<path d="M4 10h12"/>',
    max: '<rect x="4.5" y="4.5" width="11" height="11" rx="1.5"/>',
    check: '<path d="m4.5 10.5 3.5 3.5 7.5-8"/>',
    checkc: '<circle cx="10" cy="10" r="7"/><path d="m6.8 10.2 2.2 2.2 4.3-4.6"/>',
    warn: '<path d="M10 3.2 17.3 16H2.7z"/><path d="M10 8v3.6"/><circle class="f" cx="10" cy="13.8" r=".9"/>',
    info: '<circle cx="10" cy="10" r="7"/><path d="M10 9v4.5"/><circle class="f" cx="10" cy="6.6" r=".9"/>',
    minus: '<circle cx="10" cy="10" r="7"/><path d="M6.8 10h6.4"/>',
    clock: '<circle cx="10" cy="10" r="7"/><path d="M10 6v4.3l2.8 1.7"/>',
    plusf: '<path d="M2.5 6.2c0-.9.7-1.7 1.6-1.7h3.5l1.7 1.8h6.6c.9 0 1.6.7 1.6 1.6v6.9c0 .9-.7 1.7-1.6 1.7H4.1c-.9 0-1.6-.8-1.6-1.7z"/><path d="M10 9v4.5M7.8 11.2h4.4"/>',
    copyR: '<path d="M3.5 10h12M11 5.5l4.5 4.5-4.5 4.5"/>',
    copyL: '<path d="M16.5 10h-12M9 5.5 4.5 10 9 14.5"/>',
    swap: '<path d="M4 7h11.5M12.5 4l3 3-3 3M16 13H4.5M7.5 10l-3 3 3 3"/>',
    lock: '<rect x="4.5" y="9" width="11" height="8" rx="1.8"/><path d="M7 9V6.5a3 3 0 0 1 6 0V9"/>',
    copyDoc: '<rect x="6.5" y="6.5" width="10" height="10" rx="2"/><path d="M13.5 6.5V5a1.5 1.5 0 0 0-1.5-1.5H5A1.5 1.5 0 0 0 3.5 5v7A1.5 1.5 0 0 0 5 13.5h1.5"/>',
    sort: '<path d="M5 8l5 5 5-5"/>',
    updown: '<path d="m6.5 8 3.5-3.5L13.5 8M6.5 12l3.5 3.5 3.5-3.5"/>',
    dashc: '<circle cx="10" cy="10" r="7" stroke-dasharray="2.4 2.6"/>',
    half: '<circle cx="10" cy="10" r="7"/><path class="f" d="M10 3a7 7 0 0 0 0 14z"/>',
    usb: '<path d="M10 3v11"/><circle cx="10" cy="15.5" r="1.7"/><path d="M10 11 6.5 9V7.2M10 9.5l3.5-2V5.8"/><rect x="5.6" y="5.4" width="1.8" height="1.8"/><circle cx="13.5" cy="5" r=".9"/>',
    gear: '<circle cx="10" cy="10" r="2.6"/><path d="M10 2.8v2.1M10 15.1v2.1M17.2 10h-2.1M4.9 10H2.8M15.1 4.9l-1.5 1.5M6.4 13.6l-1.5 1.5M15.1 15.1l-1.5-1.5M6.4 6.4 4.9 4.9"/>',
    arrows: '<path d="M7 16V4M4 7l3-3 3 3M13 4v12M10 13l3 3 3-3"/>',
    sliders: '<path d="M3.5 6h8M15.5 6h1M3.5 14h2M9.5 14h7"/><circle cx="13.5" cy="6" r="1.8"/><circle cx="7.5" cy="14" r="1.8"/>',
  };
  const icon = (n, c = "") => `<svg class="i ${c}" viewBox="0 0 20 20">${I[n] || ""}</svg>`;

  const hash = (s) => {
    let h = 2166136261;
    for (const ch of s) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619); }
    return h >>> 0;
  };
  const PAL = [[212, 62, 42], [24, 78, 52], [352, 58, 44], [164, 46, 36], [44, 86, 54], [268, 42, 44], [194, 72, 44], [8, 66, 46], [122, 30, 36], [228, 30, 30], [300, 35, 40], [36, 40, 62]];
  const coverBg = (t) => {
    const h = hash(t), a = PAL[h % PAL.length], b = PAL[(h >>> 5) % PAL.length], k = (h >>> 11) % 5;
    const c1 = `hsl(${a[0]} ${a[1]}% ${a[2]}%)`, c2 = `hsl(${b[0]} ${b[1]}% ${Math.max(14, b[2] - 18)}%)`, c3 = `hsl(${a[0]} ${a[1]}% ${Math.min(82, a[2] + 24)}%)`;
    return [
      `radial-gradient(circle at 70% 30%, ${c3} 0 20%, transparent 21%), linear-gradient(160deg, ${c1}, ${c2})`,
      `linear-gradient(180deg, ${c1} 0 58%, ${c2} 58% 100%)`,
      `repeating-linear-gradient(90deg, ${c1} 0 12%, ${c2} 12% 19%)`,
      `radial-gradient(120% 90% at 0% 100%, ${c3} 0%, transparent 55%), linear-gradient(135deg, ${c2}, ${c1})`,
      `linear-gradient(90deg, transparent 0 36%, ${c3} 36% 44%, transparent 44%), linear-gradient(200deg, ${c1}, ${c2})`,
    ][k];
  };
  const photoBg = (n) => {
    const h = hash(n), sky = 192 + (h % 34), land = [28, 96, 150, 210, 18][(h >>> 5) % 5], hz = 46 + ((h >>> 9) % 22);
    const sun = (h >>> 14) % 3 === 0 ? `radial-gradient(circle at ${24 + ((h >>> 16) % 50)}% ${hz - 14}%, hsl(44 96% 78%) 0 9%, transparent 10%), ` : "";
    const dusk = (h >>> 18) % 4 === 0;
    return `${sun}linear-gradient(180deg, hsl(${dusk ? 24 : sky} ${dusk ? 80 : 68}% ${dusk ? 66 : 64 + ((h >>> 20) % 14)}%) 0 ${hz}%, hsl(${land} ${30 + ((h >>> 22) % 25)}% ${26 + ((h >>> 24) % 20)}%) ${hz}% 100%)`;
  };
  const cover = (t, s = 18) => `<div class="cover" style="width:${s}px;height:${s}px;background:${coverBg(t)}"></div>`;
  const FILEICON = { pdf: ["doc", "#e5483d"], txt: ["doc", "var(--text2)"], xls: ["doc", "#1e9e58"], zip: ["archive", "#b8873a"], audio: ["note", "var(--text2)"] };
  const thumb = (t, n, s = 18) => {
    if (t === "folder") return icon("folder", "afolder");
    if (t === "album") return cover(n, s);
    if (t === "img" || t === "vid" || t === "raw") return `<div class="thumb ${t} ${s > 20 ? "l" : ""}" style="width:${s}px;height:${s}px;background:${photoBg(n)}"></div>`;
    const [ic, col] = FILEICON[t] || ["doc", "var(--text2)"];
    return `<span class="ficonw ${s > 20 ? "l" : ""}" style="color:${col}">${icon(ic, "ficon")}</span>`;
  };
  const ring = (p) =>
    `<svg class="ring" viewBox="0 0 28 28"><circle cx="14" cy="14" r="11" style="fill:none;stroke:var(--ctl2);stroke-width:3"/><circle cx="14" cy="14" r="11" transform="rotate(-90 14 14)" style="fill:none;stroke:var(--accent);stroke-width:3;stroke-linecap:round;stroke-dasharray:${((2 * Math.PI * 11 * p) / 100).toFixed(1)} 999"/></svg>`;

  // ---------- building blocks ----------
  function sidebar({ sel = "", busy = "" } = {}) {
    const s = (k) => (sel === k ? "sel" : "");
    const dev = (k, ic, name, line, storages, dim = false) => `
      <div class="sb-i dev ${dim ? "dim" : ""}">${icon(ic)}<div><b>${name}</b><small>${busy === k ? '<span class="chip-busy">Busy · held by macOS</span>' : line}</small></div>${dim ? "" : `<span class="r eject">${icon("eject")}</span>`}</div>
      ${busy === k ? "" : storages.map(([sk, sic, sl, free, pct]) => `<div class="sb-i sub ${s(sk)}">${icon(sic)}${sl}<span class="r">${free}</span></div><div class="sb-cap"><i style="width:${pct}%"></i></div>`).join("")}`;
    const local = [["desk", "desktop", "Desktop"], ["docs", "doc", "Documents"], ["dl", "download", "Downloads"], ["pics", "image", "Pictures"], ["music", "note", "Music"]];
    if (plat === "mac") local.push(["home", "home", "Home"]);
    return `<aside class="sidebar">
      <div>
        <div class="sb-h">Devices</div>
        ${dev("s23", "phone", "Galaxy S23", "USB 3 · MTP", [["s23int", "chip", "Internal", "182 GB free", 29]])}
        ${dev("sp", "dap", "SP3000", "USB 2.0 · MTP", [["spint", "chip", "Internal", "318 GB free", 38], ["spsd", "sd", "microSD", "412 GB free", 59]])}
        ${dev("tab", "tablet", "Galaxy Tab S9", "Not connected", [], true)}
      </div>
      <div>
        <div class="sb-h">${plat === "win" ? "This PC" : "Mac"}</div>
        ${local.map(([k, ic, l]) => `<div class="sb-i ${s(k)}">${icon(ic)}${l}</div>`).join("")}
      </div>
      <div>
        <div class="sb-h">Sync Pairs</div>
        <div class="sb-i">${icon("sync")}Camera → Phone Imports<span class="r">${busy ? "" : '<span class="badge">450</span>'}</span></div>
        <div class="sb-i">${icon("sync")}HiRes → SP3000 microSD<span class="r"><span class="badge">44</span></span></div>
        <div class="sb-i dim">${icon("sync")}Documents ↔ Tab S9</div>
      </div>
    </aside>`;
  }

  function toolbar({ title, sub, copy, copyIcon = "copyR", insp = false, badge = 0, disabled = false }) {
    const dim = disabled ? "opacity:.45" : "";
    return `<div class="toolbar">
      <span class="tb">${icon("back")}</span><span class="tb dim">${icon("fwd")}</span>
      <div class="title"><b>${title}</b><small>${sub}</small></div>
      <div class="spacer"></div>
      <div class="seg"><span class="tb on">${icon("list")}</span><span class="tb">${icon("columns")}</span><span class="tb">${icon("grid")}</span></div>
      <span class="tb">${icon("swap")}</span>
      <span class="tb">${icon("plusf")}</span>
      <div class="vsep"></div>
      <span class="btn" style="${dim}">${icon(copyIcon)}${copy}</span>
      <span class="btn" style="${dim}">${icon("sync")}Sync${badge ? `<span class="badge">${badge}</span>` : ""}</span>
      <span class="tb ${insp ? "on" : ""}">${icon("sidebarR")}</span>
      <div class="search">${icon("search")}<span>Filter</span></div>
    </div>`;
  }

  const crumbs = (parts) =>
    parts.map(([ic, l], i) => `<span class="crumb ${i === parts.length - 1 ? "last" : ""}">${ic ? icon(ic) : ""}${l}</span>`).join(icon("chev", "sepc"));
  const hostPath = (parts) => [plat === "win" ? ["desktop", "This PC"] : ["home", "Home"], ...parts.map((p) => ["", p])];
  const WHERE_HOST = `<span class="where">${icon("desktop")}This ${HOST}</span>`;
  const whereDev = (ic, label) => `<span class="where dev">${icon(ic)}${label}</span>`;

  const ST = {
    same: () => `<span class="st ok">${icon("checkc")}Same</span>`,
    differs: () => `<span class="st warn">${icon("half")}Differs</span>`,
    notdev: () => `<span class="st none">${icon("dashc")}Not on device</span>`,
    notmac: () => `<span class="st none">${icon("dashc")}Not on ${HOST}</span>`,
    copying: (p) => `<span class="st copy"><span class="mini"><i style="width:${p}%"></i></span>${p}%</span>`,
    queued: () => `<span class="st muted">${icon("clock")}Queued</span>`,
    blank: () => "",
  };

  function row([n, t, k, z, s = "blank", f = "", p = 0], showKind) {
    if (t === "summary") return `<div class="row summary"><div class="name"><span class="sp10"></span>${icon("clock")}<span class="t">${n}</span></div></div>`;
    const m = t === "album" && n.match(/^(\d{4} -)\s(.*)$/);
    const label = m ? `<span class="yr">${m[1]}</span> ${m[2]}` : n;
    const disc = t === "folder" || t === "album" ? icon("chev", "disc") : '<span class="sp10"></span>';
    return `<div class="row ${f}"><div class="name">${disc}${thumb(t, n)}<span class="t">${label}</span></div><div>${ST[s](p)}</div>${showKind ? `<div class="cell">${k}</div>` : ""}<div class="cell r">${z}</div></div>`;
  }

  function pane({ active, path, where, cols = [], rows = [], foot = "", grid = "", body }) {
    const showKind = cols.length === 4;
    const head = cols.map((c, i) => `<span class="${i === cols.length - 1 ? "r" : ""} ${i === 0 ? "on" : ""}">${c}${i === 0 ? icon("sort") : ""}</span>`).join("");
    const filler = Array.from({ length: Math.max(0, 30 - rows.length) }, () => `<div class="row"></div>`).join("");
    return `<section class="pane ${active ? "active" : ""}" style="--grid:${grid}">
      <div class="crumbs">${crumbs(path)}${where}</div>
      ${body || `<div class="cols">${head}</div><div class="rows">${rows.map((r) => row(r, showKind)).join("")}${filler}</div><div class="foot">${foot}</div>`}
    </section>`;
  }
  const devFoot = (items, free, pct, add = 0) =>
    `<span>${items}</span><span class="capwrap"><span class="cap"><i style="width:${pct}%"></i>${add ? `<i class="add" style="width:${add}%"></i>` : ""}</span>${free}</span>`;

  function tbarActive({ pct, title, sub, done, speed, left }) {
    return `<div class="tbar">${ring(pct)}
      <div><div class="ttl">${title}</div><div class="sub">${sub}</div></div>
      <div><div class="prog"><i style="width:${pct}%"></i></div><div class="tstats"><span>${done}</span><span><b>${speed}</b></span><span>${left}</span></div></div>
      <div class="acts"><span class="tb">${icon("pause")}</span><span class="tb">${icon("chevU")}</span></div></div>`;
  }
  const tbarDone = (sub, avg) => `<div class="tbar done"><span class="st ok" style="justify-content:center">${icon("checkc", "ring")}</span>
      <div><div class="ttl">All transfers complete</div><div class="sub">${sub}</div></div>
      <div><div class="prog ok"><i style="width:100%"></i></div><div class="tstats"><span>Average <b>${avg}</b></span><span>0 errors</span><span>Today, 10:42</span></div></div>
      <div class="acts"><span class="tb">${icon("chevU")}</span></div></div>`;

  const main = (tb, content, bottom = "") => `<main class="main">${tb}${content}${bottom}</main>`;
  const titlebar = () => `<div class="titlebar"><span class="appic"></span>ReMTP<span class="caps"><span>${icon("min")}</span><span>${icon("max")}</span><span>${icon("x")}</span></span></div>`;
  const frame = (sb, m, { overlay = "", inactive = false } = {}) =>
    `<div class="win">${plat === "win" ? titlebar() : `<div class="lights ${inactive ? "off" : ""}"><i></i><i></i><i></i></div>`}${sb}${m}${overlay}</div>`;
  const GRID_K = "minmax(0,1fr) 112px 108px 62px";
  const GRID_3 = "minmax(0,1fr) 100px 56px";

  // ---------- data ----------
  const F = (n, t, k, z, s, f, p) => [n, t, k, z, s, f, p];
  const LIS_MAC = [
    F("Edited", "folder", "Folder", "96 MB", "differs"),
    F("Raw", "folder", "Folder", "3.2 GB", "notdev"),
    F("Boarding pass.pdf", "pdf", "PDF document", "182 KB", "same", "sel"),
    F("Hotel confirmation.pdf", "pdf", "PDF document", "96 KB", "same", "sel"),
    F("IMG_0412.HEIC", "img", "HEIC image", "2.8 MB", "same", "sel"),
    F("IMG_0413.HEIC", "img", "HEIC image", "3.1 MB", "same", "sel"),
    F("IMG_0415.MOV", "vid", "QuickTime movie", "212 MB", "same", "sel"),
    F("IMG_0416.HEIC", "img", "HEIC image", "2.6 MB", "same", "sel"),
    F("IMG_0418.HEIC", "img", "HEIC image", "3.4 MB", "same", "sel"),
    F("IMG_0419.MOV", "vid", "QuickTime movie", "148 MB", "same", "sel"),
    F("IMG_0421.HEIC", "img", "HEIC image", "2.9 MB", "same", "sel"),
    F("IMG_0422.MOV", "vid", "QuickTime movie", "304 MB", "copying", "sel", 62),
    F("IMG_0424.HEIC", "img", "HEIC image", "3.0 MB", "queued", "sel"),
    F("IMG_0425.HEIC", "img", "HEIC image", "3.1 MB", "queued", "sel"),
    F("IMG_0427.MOV", "vid", "QuickTime movie", "96 MB", "queued", "sel"),
    F("IMG_0428.HEIC", "img", "HEIC image", "2.7 MB", "queued", "sel"),
    F("IMG_0430.HEIC", "img", "HEIC image", "3.2 MB", "queued", "sel"),
    F("IMG_0431.HEIC", "img", "HEIC image", "2.8 MB", "queued", "sel"),
    F("IMG_0433.MOV", "vid", "QuickTime movie", "188 MB", "queued", "sel"),
    F("IMG_0434.HEIC", "img", "HEIC image", "3.0 MB", "queued", "sel"),
    F("Lisbon map.png", "img", "PNG image", "4.2 MB", "notdev"),
    F("Lisbon 2026 (backup).zip", "zip", "ZIP archive", "1.9 GB", "notdev"),
    F("Notes.txt", "txt", "Plain text", "3 KB", "notdev"),
    F("Tram 28 timelapse.mp4", "vid", "MPEG-4 movie", "1.2 GB", "notdev"),
    F("Trip expenses.xlsx", "xls", "Excel workbook", "48 KB", "notdev"),
  ];
  const LIS_DEV = [
    ...LIS_MAC.slice(2, 11).map((r) => [r[0], r[1], r[2], r[3], "same"]),
    F("IMG_0422.MOV", "vid", "QuickTime movie", "188 MB", "copying", "ghost", 62),
    ["8 more files queued", "summary"],
    F("Screenshot_20261103.png", "img", "PNG image", "1.1 MB", "notmac"),
  ];

  function lisbonScene(opts = {}) {
    return frame(
      sidebar({ sel: "s23int" }),
      main(
        toolbar({ title: "Lisbon 2026", sub: "Download · Galaxy S23", copy: `Copy to ${HOST}`, copyIcon: "copyL" }),
        `<div class="content"><div class="panes">
          ${pane({ active: false, path: hostPath(["Pictures", "Lisbon 2026"]), where: WHERE_HOST, cols: ["Name", "On Galaxy S23", "Kind", "Size"], rows: LIS_MAC, grid: GRID_K, foot: `<span>25 items, 18 selected · 984 MB</span><span>1.21 TB available</span>` })}
          ${pane({ active: true, path: [["phone", "Galaxy S23"], ["", "Internal storage"], ["", "Download"], ["", "Lisbon 2026"]], where: whereDev("phone", "Galaxy S23 · Internal"), cols: ["Name", `On ${HOST}`, "Kind", "Size"], rows: LIS_DEV, grid: GRID_K, foot: devFoot("12 items · 9 arriving", "182 GB free of 256 GB", 29, 0.4) })}
        </div></div>`,
        tbarActive({ pct: 57, title: "Copying 18 files to Galaxy S23 › Download › Lisbon 2026", sub: "IMG_0422.MOV · file 10 of 18", done: "<b>563</b> of 984 MB", speed: "214 MB/s", left: "about 2 s left" }),
      ),
      opts,
    );
  }

  const S = {};
  S.main = () => lisbonScene();
  S.windows = () => lisbonScene();

  // ---------- transfers ----------
  const dng = (i) => `IMG_0${500 + i}.DNG`;
  const dngSize = (i) => `${(24 + (hash(dng(i)) % 160) / 10).toFixed(1)} MB`;
  const RAW_MAC = Array.from({ length: 14 }, (_, k) => {
    const i = 55 + k;
    return [dng(i), "raw", "DNG raw image", dngSize(i), i < 64 ? "same" : i === 64 ? "copying" : "queued", "", 62];
  });
  const RAW_DEV = [
    ...Array.from({ length: 9 }, (_, k) => [dng(55 + k), "raw", "DNG raw image", dngSize(55 + k), "same"]),
    [dng(64), "raw", "DNG raw image", "20 MB", "copying", "ghost", 62],
    ["36 more files queued", "summary"],
  ];
  const spark = () => {
    const n = 100, W = 600, H = 58, max = 260, pts = [];
    for (let i = 0; i < n; i++) {
      const ramp = Math.min(1, (i + 1) / 3);
      const dip = i % 6 === 5 ? -14 : 0;
      const noise = Math.sin(i * 1.7) * 3 + Math.sin(i * 0.43) * 4 + Math.cos(i * 2.9) * 2;
      pts.push([(i / (n - 1)) * W, H - (((214 + noise + dip) * ramp) / max) * H]);
    }
    const line = pts.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)} ${y.toFixed(1)}`).join(" ");
    const avg = H - (211 / max) * H;
    return `<svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">
      <path d="${line} L${W} ${H} L0 ${H} Z" style="fill:var(--accent-soft)"/>
      <path d="${line}" style="fill:none;stroke:var(--accent);stroke-width:1.6;vector-effect:non-scaling-stroke"/>
      <path d="M0 ${avg.toFixed(1)} H${W}" style="stroke:var(--text3);stroke-width:1;stroke-dasharray:3 4;vector-effect:non-scaling-stroke"/>
    </svg>`;
  };

  S.transfers = () =>
    frame(
      sidebar({ sel: "pics" }),
      main(
        toolbar({ title: "Raw", sub: "Lisbon 2026 · This Mac", copy: "Copy to Galaxy S23" }),
        `<div class="content"><div class="panes">
          ${pane({ active: true, path: hostPath(["Pictures", "Lisbon 2026", "Raw"]), where: WHERE_HOST, cols: ["Name", "On Galaxy S23", "Kind", "Size"], rows: RAW_MAC, grid: GRID_K, foot: `<span>100 items · 3.2 GB</span><span>1.21 TB available</span>` })}
          ${pane({ active: false, path: [["phone", "Galaxy S23"], ["", "Download"], ["", "Lisbon 2026"], ["", "Raw"]], where: whereDev("phone", "Galaxy S23 · Internal"), cols: ["Name", "On Mac", "Kind", "Size"], rows: RAW_DEV, grid: GRID_K, foot: devFoot("64 items · 36 arriving", "182 GB free of 256 GB", 29, 1.2) })}
        </div></div>`,
        `<div class="drawer">
          <div class="dhead">
            <h3>Transfers</h3>
            <div class="seg txt"><span class="tb on">In progress <span class="badge gray">2</span></span><span class="tb">Needs attention <span class="badge">1</span></span><span class="tb">Done today <span class="badge gray">14</span></span></div>
            <div class="spacer"></div>
            <span class="btn small">${icon("pause")}Pause All</span>
            <span class="tb">${icon("chevD")}</span>
          </div>
          <div class="speed">
            <div><div class="big">214<small>MB/s</small></div><div class="note">${icon("usb")}USB 3 · 5 Gb/s · MTP</div></div>
            <div class="sparkwrap">${spark()}<span class="ceil">average 211 MB/s · each dip is a file boundary</span></div>
            <dl class="facts"><dt>Copied</dt><dd>2.1 of 3.2 GB</dd><dt>Time left</dt><dd>about 6 s</dd><dt>Average per file</dt><dd class="g">0.18 s</dd><dt>Device wait per file</dt><dd>28 ms</dd><dt>Idle between files</dt><dd>3 ms</dd></dl>
          </div>
          <div class="queue">
            <div class="q cur">${thumb("raw", dng(64), 34)}
              <div><div class="nm">Raw · 100 files</div><div class="ds">Lisbon 2026 › Raw → Galaxy S23 › Download › Lisbon 2026 › Raw</div></div>
              <div class="pr"><div class="prog"><i style="width:64%"></i></div><div class="tstats"><span>64 of 100 files</span><span><b>2.1</b> of 3.2 GB</span></div></div>
              <div class="ac"><span class="tb">${icon("pause")}</span><span class="tb">${icon("x")}</span></div></div>
            <div class="f"><span></span>${icon("image")}<span class="fn">${dng(64)}</span><div><div class="prog"><i style="width:62%"></i></div></div><span class="fs">20 / 33 MB</span></div>
            <div class="f"><span></span>${icon("image")}<span class="fn">${dng(65)} · ${dng(66)} · ${dng(67)}</span><span class="stt ready">${icon("check")}Read ahead · ready to send</span><span class="fs">96 MB</span></div>
            <div class="q">${thumb("vid", "Tram 28 timelapse.mp4", 34)}
              <div><div class="nm">Tram 28 timelapse.mp4</div><div class="ds">Lisbon 2026 → Galaxy S23 › Download › Lisbon 2026</div></div>
              <div class="pr"><div class="prog"><i style="width:0%"></i></div><div class="tstats"><span>Queued</span><span>1.2 GB</span></div></div>
              <div class="ac"><span class="tb">${icon("updown")}</span><span class="tb">${icon("x")}</span></div></div>
            <div class="qsec">Needs attention</div>
            <div class="q issue">${thumb("img", "IMG_0458.HEIC", 34)}
              <div><div class="nm">IMG_0458.HEIC</div><div class="ds warn">Already on Galaxy S23 with a different size (2.9 MB there, 3.1 MB here).</div></div>
              <div class="pr" style="display:flex;gap:6px;justify-content:flex-end"><span class="btn small">Replace</span><span class="btn small">Keep Both</span><span class="btn small">Skip</span></div>
              <div class="ac"><span class="tb">${icon("x")}</span></div></div>
          </div>
          <div class="dfoot">${icon("info")}Galaxy S23 replaces file dates on upload, so ReMTP remembers the originals and compares by size and checksum. If the cable comes out, the queue resumes when the phone is back.</div>
        </div>`,
      ),
    );

  // ---------- sync ----------
  const camRows = (n, st) =>
    Array.from({ length: n }, (_, k) => {
      const d = 18 - Math.floor(k / 3), hh = (9 + k * 5) % 24, mm = (k * 17) % 60, ss = (k * 23) % 60, vid = k % 5 === 1;
      const pad = (x) => String(x).padStart(2, "0");
      const name = `${vid ? "VID" : "IMG"}_202611${pad(d)}_${pad(hh)}${pad(mm)}${pad(ss)}.${vid ? "mp4" : "jpg"}`;
      return [name, vid ? "vid" : "img", vid ? "MPEG-4 movie" : "JPEG image", vid ? `${((120 + k * 37) % 900) + 60} MB` : `${(3.1 + (k % 4) * 0.4).toFixed(1)} MB`, st(k)];
    });
  const plan = [
    ["November 2026", "212 files"],
    ["IMG_20261118_093412.jpg", "img", "add", "New · photo · taken Nov 18 at 09:34 · 4000×3000", "4.1 MB"],
    ["VID_20261117_201455.mp4", "vid", "add", "New · 4K video · 2:14", "1.2 GB"],
    ["IMG_20261117_184020.jpg", "img", "con", "A different file with this name is already in Phone Imports (3.9 MB there, 4.2 MB here)", "4.2 MB"],
    ["IMG_20261116_121503.jpg", "img", "add", "New · photo · taken Nov 16 at 12:15", "3.8 MB"],
    ["October 2026", "238 files"],
    ["Screenshot_20261030_220114.png", "img", "add", "New · screenshot · excluded by you", "1.1 MB", "dim"],
    ["IMG_20261029_171209.jpg", "img", "add", "New · photo · taken Oct 29 at 17:12", "3.6 MB"],
    ["VID_20261028_090301.mp4", "vid", "add", "New · 4K video · 0:48", "412 MB"],
  ];
  const PILL = { add: ["add", "Add"], upd: ["upd", "Update"] };

  S.sync = () =>
    frame(
      sidebar({ sel: "s23int" }),
      main(
        toolbar({ title: "Camera", sub: "DCIM · Galaxy S23", copy: "Copy to Mac", copyIcon: "copyL", badge: 450 }),
        `<div class="content"><div class="panes">
          ${pane({ active: false, path: hostPath(["Pictures", "Phone Imports"]), where: WHERE_HOST, cols: ["Name", "On Galaxy S23", "Kind", "Size"], rows: camRows(26, () => "same"), grid: GRID_K, foot: `<span>5,793 items</span><span>1.21 TB available</span>` })}
          ${pane({ active: true, path: [["phone", "Galaxy S23"], ["", "Internal storage"], ["", "DCIM"], ["", "Camera"]], where: whereDev("phone", "Galaxy S23 · Internal"), cols: ["Name", "On Mac", "Kind", "Size"], rows: camRows(26, (k) => (k < 12 ? "notmac" : "same")), grid: GRID_K, foot: devFoot("6,214 items", "182 GB free of 256 GB", 29) })}
        </div></div>`,
        tbarDone("14 transfers · 38.2 GB copied and verified today", "186 MB/s"),
      ),
      {
        overlay: `<div class="overlay"><div class="sheet">
        <div class="sh-head"><div class="sh-icon">${icon("sync")}</div><div>
          <h2>Sync “Camera” <span class="arrow">→</span> Phone Imports</h2>
          <p>Galaxy S23 › DCIM › Camera → ~/Pictures/Phone Imports · compared 6,214 files in 0.9 s. Nothing changes until you press Sync.</p></div>
          <div class="seg txt dir"><span class="tb on">Galaxy S23 → Mac</span><span class="tb">Mac → Galaxy S23</span></div></div>
        <div class="space">
          <div class="bar"><i class="used" style="width:39.5%"></i><i class="add" style="width:1.2%"></i></div>
          <div class="legend"><span><i style="background:var(--text3)"></i>Mac used <b>790 GB</b></span><span><i style="background:var(--accent)"></i>This sync adds <b>18.4 GB</b></span><span><i style="background:var(--ctl2)"></i>Free afterwards <b>1.19 TB</b> of 2 TB</span></div>
        </div>
        <div class="chips">
          <span class="chip on">Changes <span class="n">452</span></span>
          <span class="chip"><i class="dot" style="background:var(--accent)"></i>Add <span class="n">450</span></span>
          <span class="chip"><i class="dot" style="background:var(--red)"></i>Conflicts <span class="n">2</span></span>
          <span class="chip"><i class="dot" style="background:var(--purple)"></i>Only in Phone Imports <span class="n">31</span></span>
          <span class="chip"><i class="dot" style="background:var(--text3)"></i>Unchanged <span class="n">5,762</span></span>
        </div>
        <div class="plan plan-fade">${plan.map((p) => {
          if (p.length === 2) return `<div class="grp">${icon("clock")}${p[0]}<span style="font-weight:400;color:var(--text3)">· ${p[1]}</span></div>`;
          const [n, t, k, why, sz, flag = ""] = p;
          const action = k === "con" ? `<span class="pop">Keep both${icon("updown")}</span>` : `<span class="pill ${PILL[k][0]}">${PILL[k][1]}</span>`;
          return `<div class="it ${flag}"><span class="cb ${flag ? "off" : ""}">${flag ? "" : icon("check")}</span>${thumb(t, n, 32)}<div style="min-width:0"><div class="nm">${n}</div><div class="why">${why}</div></div>${action}<span class="sz">${sz}</span></div>`;
        }).join("")}</div>
        <div class="notes">
          <div class="info">${icon("info")}<span><b>Original dates are kept.</b> Galaxy S23 reports when each photo and video was taken.</span></div>
          <div class="info">${icon("info")}<span><b>31 files</b> are only in Phone Imports. They’ll be left alone.</span><a>Show</a></div>
        </div>
        <div class="sh-foot">
          <span class="opt">After copying<span class="pop">Keep on phone${icon("updown")}</span></span>
          <span class="opt">Verify<span class="pop">Size + checksum${icon("updown")}</span></span>
          <span class="spacer"></span>
          <span class="btn">Cancel</span>
          <span class="btn primary">Sync 451 Files · 18.4 GB</span>
        </div>
      </div></div>`,
      },
    );

  // ---------- inspector (audio player) ----------
  const alb = (n, s, z, f = "") => [n, "album", "", z, s, f];
  const MD_MAC = [
    alb("1954 - Walkin'", "same", "0.9 GB"), alb("1956 - 'Round About Midnight", "same", "1.6 GB"), alb("1957 - Miles Ahead", "same", "1.1 GB"),
    alb("1958 - Milestones", "same", "1.7 GB"), alb("1959 - Kind of Blue", "same", "2.6 GB"), alb("1960 - Sketches of Spain", "same", "2.1 GB"),
    alb("1961 - Someday My Prince Will Come", "differs", "1.2 GB"), alb("1965 - E.S.P.", "notdev", "1.3 GB"), alb("1967 - Miles Smiles", "notdev", "1.4 GB"),
    alb("1969 - In a Silent Way", "same", "1.6 GB"), alb("1970 - Bitches Brew", "same", "3.1 GB"), ["folder.jpg", "img", "", "388 KB", "blank"],
  ];
  const MD_DEV = [
    alb("1954 - Walkin'", "same", "0.9 GB"), alb("1956 - 'Round About Midnight", "same", "1.6 GB"), alb("1957 - Miles Ahead", "same", "1.1 GB"),
    alb("1958 - Milestones", "same", "1.7 GB"), alb("1959 - Kind of Blue", "same", "2.6 GB", "sel"), alb("1960 - Sketches of Spain", "same", "2.1 GB"),
    alb("1961 - Someday My Prince Will Come", "differs", "1.2 GB"), alb("1964 - Four & More", "notmac", "1.0 GB"),
    alb("1969 - In a Silent Way", "same", "1.6 GB"), alb("1970 - Bitches Brew", "same", "3.1 GB"),
  ];
  const KOB = `radial-gradient(60% 50% at 68% 34%, rgba(120,170,255,.55) 0%, transparent 70%), radial-gradient(80% 60% at 20% 90%, rgba(40,90,200,.5) 0%, transparent 70%), linear-gradient(180deg, #13284f 0%, #0a1430 100%)`;
  const TRACKS = [["So What", "9:22"], ["Freddie Freeloader", "9:46"], ["Blue in Green", "5:37"], ["All Blues", "11:33"], ["Flamenco Sketches", "9:26"]];

  S.inspector = () =>
    frame(
      sidebar({ sel: "spint" }),
      main(
        toolbar({ title: "Miles Davis", sub: "Internal · SP3000", copy: "Copy to Mac", copyIcon: "copyL", insp: true, badge: 44 }),
        `<div class="content with-insp"><div class="panes">
          ${pane({ active: false, path: hostPath(["Music", "HiRes", "Miles Davis"]), where: WHERE_HOST, cols: ["Name", "On SP3000", "Size"], rows: MD_MAC, grid: GRID_3, foot: `<span>12 items</span><span>1.21 TB available</span>` })}
          ${pane({ active: true, path: [["dap", "SP3000"], ["", "Internal"], ["", "Music"], ["", "Miles Davis"]], where: whereDev("dap", "SP3000 · Internal"), cols: ["Name", "On Mac", "Size"], rows: MD_DEV, grid: GRID_3, foot: `<span>10 items, 1 selected</span><span class="capwrap"><span class="cap" style="width:70px"><i style="width:62%"></i></span>318 GB free</span>` })}
        </div>
        <aside class="insp">
          <div class="cover big" style="width:264px;height:264px;background:${KOB}"><div class="lbl"><small>Miles Davis</small><b>Kind of Blue</b></div></div>
          <div><h2>Kind of Blue</h2><div class="by">Miles Davis · 1959 · Columbia</div></div>
          <dl class="kv"><dt>Kind</dt><dd>Album · FLAC 24-bit / 192 kHz</dd><dt>Tracks</dt><dd>5 · 45:44</dd><dt>Size</dt><dd>2.6 GB</dd><dt>On device</dt><dd>Internal › Music › Miles Davis</dd></dl>
          <div class="card ok"><div class="hd">${icon("checkc")}Same on SP3000 and Mac</div><div class="p">All 5 tracks match by size and checksum. Verified Nov 17 at 21:04.</div></div>
          <div><div class="sec" style="margin-bottom:2px">Tracks</div><div class="tracks">${TRACKS.map(([t, d], i) => `<div><span>${i + 1}</span><span>${t}</span><span>${d}</span></div>`).join("")}</div></div>
        </aside></div>`,
        tbarDone("14 transfers · 38.2 GB copied and verified today", "37.6 MB/s"),
      ),
    );

  // ---------- device access ----------
  const PICS = [
    ["Family", "64 GB"], ["Lisbon 2026", "4.4 GB"], ["Phone Imports", "212 GB"], ["Scans", "1.2 GB"], ["Screenshots", "3.1 GB"], ["Wallpapers", "880 MB"],
  ].map(([n, z], i) => [n, "folder", "Folder", z, "blank", i === 1 ? "sel" : ""]);
  PICS.push(["Photos Library.photoslibrary", "img", "Photos library", "412 GB", "blank"]);

  S.access = () =>
    frame(
      sidebar({ sel: "pics", busy: "s23" }),
      main(
        toolbar({ title: "Pictures", sub: "This Mac", copy: "Copy to Galaxy S23", disabled: true }),
        `<div class="content"><div class="panes">
          ${pane({ active: true, path: hostPath(["Pictures"]), where: WHERE_HOST, cols: ["Name", "On Galaxy S23", "Kind", "Size"], rows: PICS, grid: GRID_K, foot: `<span>7 items, 1 selected</span><span>1.21 TB available</span>` })}
          ${pane({ active: false, path: [["phone", "Galaxy S23"]], where: whereDev("phone", "Galaxy S23 · connecting"), body: `<div class="prompt-wrap" style="grid-row:2 / 5"><div class="prompt">
            <div class="devart">${icon("phone")}<span class="lock">${icon("lock")}</span></div>
            <h2>macOS is holding your Galaxy S23</h2>
            <p>When you plugged it in, macOS’s photo-import service (<b>ptpcamerad</b>) took the USB connection, so no other app can reach the phone.</p>
            <p>ReMTP can pause that service while the phone is connected and switch it back on when you disconnect or quit. Photos and Image Capture keep working afterwards.</p>
            <div class="acts"><span class="btn primary">Release Galaxy S23</span><span class="btn">Not Now</span></div>
            <label class="check"><span class="cb off"></span>Do this automatically for this device</label>
            <div class="details"><div class="hd">${icon("chevD")}Details</div>
              <dl><dt>Held by</dt><dd>ptpcamerad (pid 812)</dd><dt>Connection</dt><dd>USB 3 · 5 Gb/s</dd><dt>Phone mode</dt><dd>File transfer (MTP)</dd></dl>
              <div class="term"><code>launchctl disable gui/501/com.apple.ptpcamerad; pkill ptpcamerad</code><span class="btn small">${icon("copyDoc")}Copy</span></div>
            </div>
          </div></div>` })}
        </div></div>`,
      ),
    );

  const picker = shot
    ? ""
    : `<nav class="picker">${SCREENS.map(([k, l]) => `<a class="${k === screen ? "on" : ""}" href="?screen=${k}&theme=${theme}">${l}</a>`).join("")}<span class="vsep"></span>${["light", "dark"].map((t) => `<a class="${t === theme ? "on" : ""}" href="?screen=${screen}&theme=${t}">${t[0].toUpperCase() + t.slice(1)}</a>`).join("")}</nav>`;

  document.getElementById("root").outerHTML = `${picker}<div class="stage">${S[screen]()}</div>`;
})();
