"use strict";
let directory = [];
const byId = id => document.getElementById(id);
function textNode(parent, tag, text, className) {
  const node = document.createElement(tag); node.textContent = text;
  if (className) node.className = className;
  parent.append(node); return node;
}
function link(parent, label, url) {
  try {
    const parsed = new URL(url); if (parsed.protocol !== "https:") return;
    const anchor = textNode(parent, "a", label); anchor.href = parsed.href; anchor.target = "_blank"; anchor.rel = "noopener noreferrer";
  } catch { /* Missing or invalid external URL. */ }
}
function renderLeads(payload) {
  const automation = payload.automation;
  const lastResearch = automation && Date.parse(automation.lastSuccessfulResearchUtc || "");
  const dateLabel = lastResearch ? new Intl.DateTimeFormat("en-US", { dateStyle: "medium", timeStyle: "short", timeZone: "America/Phoenix" }).format(lastResearch) : payload.researchedOn;
  const stale = lastResearch && Date.now() - lastResearch > 36 * 3600000;
  byId("research-date").textContent = automation
    ? `LAST RESEARCH ${dateLabel} (Phoenix) / ${automation.schedule}${stale ? " / RESEARCH OVERDUE" : ""}`
    : `RESEARCHED ${payload.researchedOn} / Recurring research setup pending`;
  byId("research-scope").textContent = payload.scope;
  if (automation && automation.requiresComputer) byId("research-scope").textContent += " The researcher runs while your Windows computer is on and signed in. The cloud job monitor continues when it is off.";
  byId("lead-list").replaceChildren();
  payload.leads.forEach(lead => {
    const card = document.createElement("article"); card.className = "outreach-card";
    textNode(card, "p", `${lead.company} / ${lead.location}`, "eyebrow");
    textNode(card, "h3", lead.role); textNode(card, "p", lead.person);
    const checked = lead.lastCheckedUtc ? `Checked ${new Date(lead.lastCheckedUtc).toLocaleDateString()}. ` : "";
    textNode(card, "p", lead.evidence); textNode(card, "small", `${checked}${lead.observedAge}. ${lead.verification}.`);
    textNode(card, "p", lead.caution, "outreach-note");
    const actions = textNode(card, "div", "", "outreach-actions"); link(actions, "Open hiring activity", lead.url);
    const details = document.createElement("details"); textNode(details, "summary", "Suggested message"); textNode(details, "p", lead.message);
    const copy = textNode(details, "button", "Copy message"); copy.type = "button";
    copy.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(lead.message); copy.textContent = "Copied"; }
      catch { copy.textContent = "Select the message above to copy"; }
    });
    card.append(details); byId("lead-list").append(card);
  });
}
function renderDirectory() {
  const query = byId("company-search").value.trim().toLowerCase();
  const selected = directory.filter(item => item.company.toLowerCase().includes(query));
  byId("directory-count").textContent = `${selected.length} of ${directory.length} companies`;
  byId("company-directory").replaceChildren();
  selected.forEach(item => {
    const card = document.createElement("article"); card.className = "outreach-card";
    textNode(card, "h3", item.company); textNode(card, "p", item.coverage, "outreach-note");
    const actions = textNode(card, "div", "", "outreach-actions");
    if (item.careersUrl) link(actions, "Company careers", item.careersUrl);
    link(actions, "Web job search", item.jobSearchUrl); link(actions, "LinkedIn hiring posts", item.postSearchUrl); link(actions, "Public post search", item.webPostSearchUrl);
    byId("company-directory").append(card);
  });
}
async function loadOutreach() {
  try {
    const response = await fetch("data/outreach.json", { cache: "no-store" });
    if (!response.ok) throw new Error("Hiring research is unavailable. Refresh after the next deployment.");
    const payload = await response.json(); renderLeads(payload); directory = payload.companies; renderDirectory();
  } catch (error) { byId("lead-list").textContent = error.message; }
}
byId("company-search").addEventListener("input", renderDirectory);
loadOutreach();
setInterval(() => { if (!document.hidden) loadOutreach(); }, 15 * 60 * 1000);
