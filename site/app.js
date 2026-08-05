"use strict";

const PAGE_SIZE = 24;
const state = {
  jobs: [],
  health: null,
  tier: "all",
  search: "",
  role: "all",
  source: "all",
  sort: "newest",
  visibleLimit: PAGE_SIZE
};

const elements = {
  healthIndicator: document.getElementById("health-indicator"),
  lastScan: document.getElementById("last-scan"),
  staleWarning: document.getElementById("stale-warning"),
  total: document.getElementById("metric-total"),
  strong: document.getElementById("metric-strong"),
  firstParty: document.getElementById("metric-first-party"),
  boards: document.getElementById("metric-boards"),
  resultCount: document.getElementById("result-count"),
  search: document.getElementById("search-input"),
  role: document.getElementById("role-filter"),
  source: document.getElementById("source-filter"),
  sort: document.getElementById("sort-filter"),
  jobList: document.getElementById("job-list"),
  empty: document.getElementById("empty-state"),
  reset: document.getElementById("reset-filters"),
  loadMore: document.getElementById("load-more"),
  jobTemplate: document.getElementById("job-template"),
  coverageSummary: document.getElementById("coverage-summary"),
  coverageDirectCount: document.getElementById("coverage-direct-count"),
  coverageBroadCount: document.getElementById("coverage-broad-count"),
  directCompanies: document.getElementById("direct-company-list"),
  broadCompanies: document.getElementById("broad-company-list"),
  footerUpdated: document.getElementById("footer-updated"),
  share: document.getElementById("share-button"),
  toast: document.getElementById("toast")
};

function normalize(value) {
  return String(value || "").toLocaleLowerCase().normalize("NFKD");
}

function toArray(value) {
  if (Array.isArray(value)) return value;
  return value === null || value === undefined || value === "" ? [] : [value];
}

function parseDate(value) {
  const parsed = Date.parse(value || "");
  return Number.isFinite(parsed) ? parsed : 0;
}

function safeUrl(value) {
  try {
    const url = new URL(value);
    return ["http:", "https:"].includes(url.protocol) ? url.href : "";
  } catch {
    return "";
  }
}

function relativeDate(value) {
  const timestamp = parseDate(value);
  if (!timestamp) return "Date not listed";
  const days = Math.round((timestamp - Date.now()) / 86400000);
  const formatter = new Intl.RelativeTimeFormat("en", { numeric: "auto" });
  if (Math.abs(days) < 1) return formatter.format(0, "day");
  if (Math.abs(days) < 45) return formatter.format(days, "day");
  const months = Math.round(days / 30);
  return formatter.format(months, "month");
}

function fullDate(value) {
  const timestamp = parseDate(value);
  if (!timestamp) return "Unknown";
  return new Intl.DateTimeFormat("en", {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short"
  }).format(timestamp);
}

function getRoleFamily(job) {
  const explicit = toArray(job.reasons).find(reason => /^Role:\s*/i.test(reason));
  if (explicit) return explicit.replace(/^Role:\s*/i, "").trim();

  const title = normalize(job.title);
  if (/physical design|place.?and.?route|\bsta\b|timing/.test(title)) return "Physical Design and STA";
  if (/verification|\buvi?m\b/.test(title)) return "Design Verification";
  if (/\bdft\b|design for test/.test(title)) return "DFT and Test";
  if (/analog|mixed.signal|layout/.test(title)) return "Analog and Mixed-Signal";
  if (/fpga/.test(title)) return "FPGA";
  if (/firmware|embedded/.test(title)) return "Firmware and Embedded";
  if (/asic|rtl|soc|digital|microarchitecture|cpu|gpu/.test(title)) return "ASIC, RTL, and SoC";
  return "Electrical Hardware";
}

function addTextElement(parent, tagName, text, className) {
  const child = document.createElement(tagName);
  child.textContent = text;
  if (className) child.className = className;
  parent.appendChild(child);
  return child;
}

function animateNumber(element, value) {
  const target = Number(value) || 0;
  const start = performance.now();
  const duration = 550;
  function frame(now) {
    const progress = Math.min((now - start) / duration, 1);
    const eased = 1 - Math.pow(1 - progress, 3);
    element.textContent = Math.round(target * eased).toLocaleString();
    if (progress < 1) requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

function showToast(message) {
  elements.toast.textContent = message;
  elements.toast.classList.add("visible");
  window.setTimeout(() => elements.toast.classList.remove("visible"), 2400);
}

function renderHealth() {
  const health = state.health;
  if (!health) return;

  const lastScanTime = parseDate(health.lastSuccessfulScanUtc);
  const stale = !lastScanTime || Date.now() - lastScanTime > 2 * 60 * 60 * 1000;
  const healthy = health.status === "healthy" && !stale;
  const label = stale ? "Scan delayed" : health.status === "healthy" ? "Monitor healthy" : "Coverage degraded";
  elements.healthIndicator.querySelector("span").textContent = label;
  elements.healthIndicator.classList.toggle("stale", stale);
  elements.healthIndicator.classList.toggle("degraded", !healthy && !stale);
  elements.lastScan.textContent = fullDate(health.lastSuccessfulScanUtc);
  elements.staleWarning.hidden = !stale;

  animateNumber(elements.total, state.jobs.length);
  animateNumber(elements.strong, state.jobs.filter(job => job.tier === "Strong").length);
  animateNumber(elements.firstParty, state.jobs.filter(job => job.sourceType === "first-party").length);
  animateNumber(elements.boards, health.directCompanyBoards);

  const directBoards = Array.isArray(health.companyBoards) ? health.companyBoards : [];
  const broadCompanies = Array.isArray(health.broadCoverageCompanies) ? health.broadCoverageCompanies : [];
  elements.coverageDirectCount.textContent = directBoards.length.toLocaleString();
  elements.coverageBroadCount.textContent = broadCompanies.length.toLocaleString();
  elements.coverageSummary.textContent = `${health.healthyDirectBoards}/${health.directCompanyBoards} direct boards healthy, plus ${health.focusedRoleSearches} focused searches.`;
  elements.footerUpdated.textContent = `DATA / ${fullDate(health.generatedUtc).toUpperCase()}`;

  elements.directCompanies.replaceChildren();
  directBoards.forEach(board => {
    const url = safeUrl(board.careersUrl);
    const chip = document.createElement(url ? "a" : "span");
    chip.textContent = board.company;
    if (!board.healthy) chip.classList.add("unhealthy");
    if (url) {
      chip.href = url;
      chip.target = "_blank";
      chip.rel = "noopener noreferrer";
    }
    elements.directCompanies.appendChild(chip);
  });

  elements.broadCompanies.replaceChildren();
  broadCompanies.forEach(company => addTextElement(elements.broadCompanies, "span", company));
}

function populateRoleFilter() {
  const roles = [...new Set(state.jobs.map(getRoleFamily))].sort((a, b) => a.localeCompare(b));
  roles.forEach(role => {
    const option = document.createElement("option");
    option.value = role;
    option.textContent = role;
    elements.role.appendChild(option);
  });
}

function filteredJobs() {
  const query = normalize(state.search);
  const filtered = state.jobs.filter(job => {
    const role = getRoleFamily(job);
    const searchable = normalize([
      job.title,
      job.company,
      job.location,
      job.seniority,
      job.workModel,
      role,
      ...toArray(job.reasons),
      ...toArray(job.warnings)
    ].join(" "));
    return (state.tier === "all" || job.tier === state.tier) &&
      (state.role === "all" || role === state.role) &&
      (state.source === "all" || job.sourceType === state.source) &&
      (!query || searchable.includes(query));
  });

  return filtered.sort((left, right) => {
    if (state.sort === "score") {
      return Number(right.fitScore) - Number(left.fitScore) || parseDate(right.postedUtc) - parseDate(left.postedUtc);
    }
    if (state.sort === "company") {
      return String(left.company).localeCompare(String(right.company)) || String(left.title).localeCompare(String(right.title));
    }
    return (parseDate(right.postedUtc) || parseDate(right.discoveredUtc)) - (parseDate(left.postedUtc) || parseDate(left.discoveredUtc));
  });
}

function appendTag(container, label, className) {
  const tag = addTextElement(container, "span", label, className);
  return tag;
}

function appendMeta(container, label) {
  if (label) addTextElement(container, "span", label);
}

function appendAction(container, label, url, primary) {
  const href = safeUrl(url);
  if (!href) return;
  const link = addTextElement(container, "a", label, primary ? "primary-action" : "");
  link.href = href;
  link.target = "_blank";
  link.rel = "noopener noreferrer";
}

function createJobCard(job, index) {
  const card = elements.jobTemplate.content.firstElementChild.cloneNode(true);
  card.classList.add(`tier-${normalize(job.tier)}`);
  card.style.animationDelay = `${Math.min(index, 10) * 35}ms`;

  card.querySelector(".score-block strong").textContent = Number(job.fitScore).toString();
  const tags = card.querySelector(".job-tags");
  appendTag(tags, job.sourceLabel, job.sourceType === "first-party" ? "" : "source-broad");
  appendTag(tags, job.tier, "tier-tag");
  appendTag(tags, getRoleFamily(job));

  card.querySelector("h3").textContent = job.title || "Untitled role";
  card.querySelector(".job-company").textContent = job.company || "Company not listed";

  const meta = card.querySelector(".job-meta");
  appendMeta(meta, job.location || "U.S. location");
  appendMeta(meta, relativeDate(job.postedUtc || job.discoveredUtc));
  appendMeta(meta, job.workModel);
  appendMeta(meta, job.employmentType);

  const reasons = card.querySelector(".job-reasons");
  toArray(job.reasons)
    .filter(reason => !/^Role:\s*/i.test(reason))
    .slice(0, 3)
    .forEach(reason => appendTag(reasons, reason));

  const warnings = toArray(job.warnings).filter(Boolean);
  if (warnings.length) {
    const warning = card.querySelector(".job-warning");
    warning.textContent = `Check before applying: ${warnings.join("; ")}`;
    warning.hidden = false;
  }

  const actions = card.querySelector(".job-actions");
  const applyLabel = job.sourceType === "first-party" ? "Apply" : "View listing";
  appendAction(actions, applyLabel, job.applyUrl || job.detailUrl, true);
  if (safeUrl(job.detailUrl) && safeUrl(job.detailUrl) !== safeUrl(job.applyUrl)) {
    appendAction(actions, "Details", job.detailUrl, false);
  }
  return card;
}

function renderJobs() {
  const matches = filteredJobs();
  const visible = matches.slice(0, state.visibleLimit);
  const fragment = document.createDocumentFragment();
  visible.forEach((job, index) => fragment.appendChild(createJobCard(job, index)));
  elements.jobList.replaceChildren(fragment);
  elements.resultCount.textContent = matches.length.toLocaleString();
  elements.empty.hidden = matches.length !== 0;
  elements.loadMore.hidden = visible.length >= matches.length;
}

function resetFilters() {
  state.tier = "all";
  state.search = "";
  state.role = "all";
  state.source = "all";
  state.sort = "newest";
  state.visibleLimit = PAGE_SIZE;
  elements.search.value = "";
  elements.role.value = "all";
  elements.source.value = "all";
  elements.sort.value = "newest";
  document.querySelectorAll(".tier-button").forEach(button => button.classList.toggle("active", button.dataset.tier === "all"));
  renderJobs();
}

function bindEvents() {
  let searchTimer;
  elements.search.addEventListener("input", event => {
    window.clearTimeout(searchTimer);
    searchTimer = window.setTimeout(() => {
      state.search = event.target.value;
      state.visibleLimit = PAGE_SIZE;
      renderJobs();
    }, 120);
  });
  elements.role.addEventListener("change", event => {
    state.role = event.target.value;
    state.visibleLimit = PAGE_SIZE;
    renderJobs();
  });
  elements.source.addEventListener("change", event => {
    state.source = event.target.value;
    state.visibleLimit = PAGE_SIZE;
    renderJobs();
  });
  elements.sort.addEventListener("change", event => {
    state.sort = event.target.value;
    renderJobs();
  });
  document.querySelectorAll(".tier-button").forEach(button => {
    button.addEventListener("click", () => {
      document.querySelectorAll(".tier-button").forEach(item => item.classList.remove("active"));
      button.classList.add("active");
      state.tier = button.dataset.tier;
      state.visibleLimit = PAGE_SIZE;
      renderJobs();
    });
  });
  elements.loadMore.addEventListener("click", () => {
    state.visibleLimit += PAGE_SIZE;
    renderJobs();
  });
  elements.reset.addEventListener("click", resetFilters);
  elements.share.addEventListener("click", async () => {
    const shareData = {
      title: "SignalPath Hardware Jobs",
      text: "Hourly U.S. early-career semiconductor and hardware job matches.",
      url: window.location.href
    };
    try {
      if (navigator.share) {
        await navigator.share(shareData);
      } else {
        await navigator.clipboard.writeText(window.location.href);
        showToast("Share link copied");
      }
    } catch (error) {
      if (error && error.name !== "AbortError") showToast("Use your browser address bar to copy the link");
    }
  });
}

async function loadSite() {
  bindEvents();
  try {
    const [jobsResponse, healthResponse] = await Promise.all([
      fetch("data/jobs.json", { cache: "no-store" }),
      fetch("data/health.json", { cache: "no-store" })
    ]);
    if (!jobsResponse.ok || !healthResponse.ok) throw new Error("Published data is unavailable");
    const payload = await jobsResponse.json();
    state.health = await healthResponse.json();
    state.jobs = Array.isArray(payload.jobs) ? payload.jobs : [];
    populateRoleFilter();
    renderHealth();
    renderJobs();
  } catch (error) {
    elements.jobList.replaceChildren();
    elements.empty.hidden = false;
    elements.empty.querySelector("h3").textContent = "The feed could not load";
    elements.empty.querySelector("p").textContent = "Refresh the page in a moment. The cloud monitor may be publishing a new scan.";
    elements.reset.hidden = true;
    elements.healthIndicator.querySelector("span").textContent = "Data unavailable";
    elements.healthIndicator.classList.add("degraded");
  }
}

loadSite();
