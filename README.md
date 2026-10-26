# SignalPath Hardware Jobs

[Open the public job board](https://sbilicho.github.io/newgrad-hardware-jobs/)

SignalPath is a no-API-key monitor for U.S. full-time early-career electrical, semiconductor, and hardware roles. It checks an engineering aggregator, focused role searches, and public company feeds every hour, including Greenhouse, Lever, Ashby, Workday, and Eightfold.

## Scope

- ASIC, RTL, SoC, digital IC, physical design, STA, DFT, and verification
- FPGA, silicon validation, post-silicon, test, product, and yield engineering
- Analog, mixed-signal, electrical hardware, embedded, and firmware
- EDA software, CAD automation, applications, circuit simulation, characterization, custom layout, and physical verification
- U.S. or U.S.-remote full-time roles only; internships, contracts, senior-only roles, and unrelated disciplines are rejected

## Relevance score

The deterministic score weights role alignment, skill overlap, hardware or semiconductor domain, and early-career fit. `Strong` is 70-100, `Good` is 50-69, and `Possible` is 30-49.

The score reflects one broad ASIC, digital, semiconductor, and electrical new-grad profile. It is not an ATS score, an eligibility decision, or a probability of selection. Always verify requirements and listing status with the employer before applying.

## Companies and hiring posts

[Open hiring research and the company directory](https://sbilicho.github.io/newgrad-hardware-jobs/outreach.html).

Broadcom, Intel, NVIDIA, Cadence, Marvell, and Microchip have direct Workday connectors. These paginate public job listings and verify descriptions before alerting. The Qualcomm adapter uses the publicly advertised Eightfold search and detail routes; rate limits and access failures appear in source health and the company directory. A 90-day lookback seeds newly added company feeds so active older matches can be surfaced. Additional details beyond a run's limit are checked in later scans.

The directory distinguishes automated direct feeds from companies covered by aggregator role searches and manual search links. It supplies focused job searches, LinkedIn content searches, and public indexed-post searches for every listed employer. A company name in the directory does not imply a working direct connector.

Hiring leads are researched twice daily at 08:00 and 20:00 America/Phoenix by `scripts/refresh_hiring_posts.ps1`. It uses the existing local Codex ChatGPT sign-in with live web search and a lightweight model, without an API key. It runs on Windows while the user is signed in; Task Scheduler catches up after missed starts. Usage counts against the existing ChatGPT allowance. The cloud job scan continues independently when the PC is off.

The researcher searches public LinkedIn posts and the wider web, validates the output, preserves lead history under `outreach/`, and publishes `config/outreach.json` through an isolated local Git clone. Publication automatically redeploys the website. Each lead retains its last-checked date; the site displays an overdue notice after 36 hours. Private inbox messages are not accessed, and no outreach is sent automatically.

Install or restore the scheduled researcher with `scripts/install_hiring_research_task.ps1`. Run `scripts/refresh_hiring_posts.ps1 -Force -NoPublish` to test without publishing, or omit `-NoPublish` for an authorized update. Logs remain under `%LOCALAPPDATA%\SamarthJobMonitor\hiring-research`. An indexed or old post is a networking lead until an active opening is verified.

## Privacy and operation

The published site contains only public job details, public links, source coverage, and scan health. It does not collect analytics, accounts, resumes, emails, application data, or personal monitor state. GitHub Actions checks every 10 minutes at offset minutes and skips all job-site requests while the latest healthy scan is under 50 minutes old. The extra checkpoints absorb delayed or dropped GitHub schedule events without repeatedly crawling job sites.
