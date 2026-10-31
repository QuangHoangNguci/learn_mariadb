"use strict";

// ---- tiện ích ----
const $ = (selector) => document.querySelector(selector);
const nf = new Intl.NumberFormat("vi-VN");
const state = { timer: null, lastMaxId: 0, firstLoad: true, refTotalShown: 0, refOffset: 0, refQuery: "", refProvince: "" };

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  Object.entries(props).forEach(([k, v]) => (k === "class" ? (node.className = v) : (node[k] = v)));
  children.forEach((c) => node.append(c));
  return node;
}

async function api(path, params = {}) {
  const query = new URLSearchParams(Object.entries(params).filter(([, v]) => v !== "" && v != null));
  const url = `/api/${path}${query.toString() ? "?" + query : ""}`;
  const res = await fetch(url, { cache: "no-store" });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function setStatus(kind, text) {
  const pill = $("#status");
  pill.className = `pill pill-${kind}`;
  pill.textContent = text;
}

function showBanner(message) {
  const banner = $("#banner");
  banner.hidden = !message;
  banner.textContent = message || "";
}

function timeOnly(iso) {
  return (iso || "").split(" ")[1] || iso || "";
}

// ---- hiển thị ----
function renderSummary(s) {
  $("#c-provinces").textContent = nf.format(s.provinces);
  $("#c-wards").textContent = nf.format(s.wards);
  $("#c-live").textContent = nf.format(s.live_total);
  $("#c-rate").textContent = nf.format(s.live_last_minute);
  $("#c-rate-sub").textContent = s.live_last_minute ? `≈ ${(s.live_last_minute / 60).toFixed(1)} bản ghi/giây` : "writer chưa ghi hoặc đã dừng";
  $("#c-last").textContent = s.last_insert_at || "chưa có";
  $("#c-node").textContent = s.served_by || "?";
  $("#c-via").textContent = s.connected_via ? `qua MaxScale ${s.connected_via}` : "";
}

function renderChart(items) {
  const W = 900, H = 220, left = 40, right = 10, top = 10, bottom = 26;
  const max = Math.max(1, ...items.map((i) => i.inserted));
  const niceMax = Math.ceil(max / 4) * 4 || 4;
  const plotW = W - left - right, plotH = H - top - bottom;
  const slot = plotW / items.length;
  const svgNS = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
  const add = (tag, attrs, text) => {
    const n = document.createElementNS(svgNS, tag);
    Object.entries(attrs).forEach(([k, v]) => n.setAttribute(k, v));
    if (text != null) n.textContent = text;
    svg.append(n);
    return n;
  };
  for (let g = 0; g <= 4; g++) {
    const y = top + plotH - (plotH * g) / 4;
    add("line", { class: "grid", x1: left, x2: W - right, y1: y, y2: y });
    add("text", { class: "axis", x: left - 6, y: y + 4, "text-anchor": "end" }, nf.format(Math.round((niceMax * g) / 4)));
  }
  items.forEach((item, idx) => {
    const h = (plotH * item.inserted) / niceMax;
    const bar = add("rect", {
      class: "bar" + (idx === items.length - 1 ? " partial" : ""),
      x: left + idx * slot + slot * 0.12, width: Math.max(1, slot * 0.76), y: top + plotH - h, height: h,
    });
    const tip = document.createElementNS(svgNS, "title");
    tip.textContent = `${item.bucket.slice(11, 16)}: ${nf.format(item.inserted)} bản ghi`;
    bar.append(tip);
  });
  // nhãn thời gian cách đều, luôn có nhãn cuối; bỏ nhãn đứng quá sát nhãn cuối để không chồng chữ
  const labelEvery = Math.max(1, Math.ceil(items.length / 8));
  const last = items.length - 1;
  items.forEach((item, idx) => {
    const regular = idx % labelEvery === 0 && last - idx >= labelEvery * 0.6;
    if (regular || idx === last) {
      add("text", { class: "axis", x: left + idx * slot + slot / 2, y: H - 8, "text-anchor": "middle" }, item.bucket.slice(11, 16));
    }
  });
  $("#chart").replaceChildren(svg);
}

function renderBars(target, rows, nameKey, valueKey) {
  const box = $(target);
  if (!rows.length) {
    box.replaceChildren(el("p", { class: "hint" }, "Chưa có dữ liệu."));
    return;
  }
  const max = Math.max(1, ...rows.map((r) => r[valueKey]));
  box.replaceChildren(...rows.map((r) =>
    el("div", { class: "bar-row" },
      el("span", { class: "name", title: r[nameKey] }, r[nameKey]),
      el("div", { class: "bar-track" }, el("div", { class: "bar-fill", style: `width:${(100 * r[valueKey]) / max}%` })),
      el("span", { class: "value" }, nf.format(r[valueKey])))));
}

function renderLive(items) {
  const body = $("#live-body");
  if (!items.length) {
    body.replaceChildren(el("tr", {}, el("td", { colSpan: 6, class: "empty" }, "Chưa có bản ghi. Hãy chạy writer_service.py trên bastion.")));
    return;
  }
  const previousMax = state.lastMaxId;
  body.replaceChildren(...items.map((r) => {
    const tr = el("tr", { class: !state.firstLoad && r.id > previousMax ? "fresh" : "" },
      el("td", { class: "mono" }, timeOnly(r.created_at)),
      el("td", { class: "mono" }, r.code),
      el("td", {}, r.full_name || r.name),
      el("td", {}, r.province_name),
      el("td", { class: "mono" }, r.postal_code || ""),
      el("td", {}, r.writer_node || ""));
    return tr;
  }));
  state.lastMaxId = Math.max(previousMax, ...items.map((r) => r.id));
  state.firstLoad = false;
}

// ---- tra cứu dữ liệu mẫu ----
async function loadWards(reset) {
  if (reset) {
    state.refOffset = 0;
    state.refQuery = $("#q").value.trim();
    state.refProvince = $("#ref-province").value;
  }
  try {
    const data = await api("wards", { q: state.refQuery, province: state.refProvince, limit: 20, offset: state.refOffset });
    const rows = data.items.map((w) => el("tr", {},
      el("td", { class: "mono" }, w.code), el("td", {}, w.full_name || w.name),
      el("td", {}, w.province_name), el("td", { class: "mono" }, w.postal_code || "")));
    const body = $("#ref-body");
    if (reset) body.replaceChildren();
    if (reset && !rows.length) body.append(el("tr", {}, el("td", { colSpan: 4, class: "empty" }, "Không tìm thấy.")));
    rows.forEach((r) => body.append(r));
    state.refOffset += data.items.length;
    $("#ref-more").hidden = !data.has_more;
  } catch (err) {
    showBanner(`Không tra cứu được: ${err.message}`);
  }
}

async function loadProvinceOptions() {
  try {
    const data = await api("provinces");
    ["#live-province", "#ref-province"].forEach((sel) => {
      const select = $(sel);
      data.items.forEach((p) => select.append(el("option", { value: p.code }, p.name)));
    });
  } catch (err) {
    showBanner(`Không tải được danh sách tỉnh: ${err.message}`);
  }
}

// ---- vòng làm mới ----
async function refresh() {
  try {
    const [summary, perMinute, byNode, byProvince, latest] = await Promise.all([
      api("summary"),
      api("live/per-minute", { minutes: $("#minutes").value }),
      api("live/by-node"),
      api("live/by-province", { limit: 10 }),
      api("live/latest", { province: $("#live-province").value, limit: 30 }),
    ]);
    renderSummary(summary);
    renderChart(perMinute.items);
    renderBars("#by-node", byNode.items, "writer_node", "rows_count");
    renderBars("#by-province", byProvince.items, "name", "live_rows");
    renderLive(latest.items);
    showBanner("");
    setStatus("ok", "đã kết nối");
    $("#updated").textContent = `Cập nhật lúc ${new Date().toLocaleTimeString("vi-VN")}`;
  } catch (err) {
    setStatus("bad", "lỗi");
    showBanner(`Không lấy được dữ liệu: ${err.message}`);
  }
}

function schedule() {
  clearTimeout(state.timer);
  if (!$("#auto").checked) return;
  state.timer = setTimeout(async () => {
    if (!document.hidden) await refresh();
    schedule();
  }, Number($("#interval").value));
}

function debounce(fn, ms) {
  let t;
  return (...args) => { clearTimeout(t); t = setTimeout(() => fn(...args), ms); };
}

async function init() {
  $("#refresh").addEventListener("click", refresh);
  $("#auto").addEventListener("change", schedule);
  $("#interval").addEventListener("change", schedule);
  $("#minutes").addEventListener("change", refresh);
  $("#live-province").addEventListener("change", () => { state.firstLoad = true; state.lastMaxId = 0; refresh(); });
  $("#q").addEventListener("input", debounce(() => loadWards(true), 300));
  $("#ref-province").addEventListener("change", () => loadWards(true));
  $("#ref-more").addEventListener("click", () => loadWards(false));
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });

  fetch("/_info").then((r) => r.json()).then((i) => { $("#foot").textContent = `Reader: ${i.reader_url}`; }).catch(() => {});
  await loadProvinceOptions();
  await Promise.all([refresh(), loadWards(true)]);
  schedule();
}

init();
