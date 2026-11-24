// Pathwright feedback relay: a Cloudflare Worker.
//
// The addon's "What went wrong?" window leaves a report for the Pathwright Updater, which posts
// it here; this opens a GitHub issue from it and answers with the issue's address. The updater
// is a public program, so it holds no secret: the GitHub token lives here, as the Worker's
// secret GITHUB_TOKEN (a fine-grained token for this one repository, Issues: read and write).
//
//   POST /   {"id": "<report id>", "report": {"report": "pathwright-feedback", ...}}
//   200      {"url": "https://github.com/<repo>/issues/<n>", "number": <n>}
//   4xx/5xx  {"error": "<why>"}
//
// What keeps it from being misused: a report must look like one (validate), each report opens
// one issue however often it is posted (its id is looked for first), and no more than
// DAILY_LIMIT issues are opened a day. The issues carry the label LABEL and nothing that puts
// them in front of the maintainer's automation: a person reads them first. Everything a report
// says is text from a stranger: it is quoted, never trusted (mentions are defused, the data
// sits in a code block).
//
// Optional: DISCORD_WEBHOOK (a secret) gets one line for each issue opened.
// Setup: relay/README.md. Tests: node relay/test.mjs.

export const REPO = "weirdr/Pathwright";
export const LABEL = "addon-report";
export const DAILY_LIMIT = 40;
const MAX_BODY = 24000;
const MAX_WORDS = 2500;
const API = "https://api.github.com";

const json = (value, status = 200) =>
    new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });

/** A posted body as { id, report }, or { error } when it is not a feedback report. */
export function validate(text) {
    if (typeof text !== "string" || text.length > MAX_BODY) return { error: "too large" };
    let body;
    try {
        body = JSON.parse(text);
    } catch {
        return { error: "not JSON" };
    }
    const { id, report } = body ?? {};
    if (typeof id !== "string" || !/^[0-9a-f-]{6,40}$/.test(id)) return { error: "no report id" };
    if (!report || typeof report !== "object" || Array.isArray(report)) return { error: "no report" };
    if (report.report !== "pathwright-feedback") return { error: "not a feedback report" };
    const words = report.what_went_wrong;
    if (typeof words !== "string" || words.trim().length < 3 || words.length > MAX_WORDS) {
        return { error: "nothing said" };
    }
    return { id, report };
}

/** Text from a report made safe to sit in an issue: no mention pings, no markup of its own. */
export function plain(value, max = 200) {
    return String(value ?? "")
        .replace(/[\u0000-\u001f\u007f]+/g, " ")
        .replace(/@/g, "@\u200b")
        .replace(/[<>]/g, (c) => (c === "<" ? "&lt;" : "&gt;"))
        .replace(/([`*_~\[\]|#])/g, "\\$1")
        .trim()
        .slice(0, max);
}

export function issueTitle(report) {
    const first = String(report.what_went_wrong).split(/\r?\n/).find((line) => line.trim()) ?? "";
    const words = first.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/@/g, "@\u200b").trim();
    return "Feedback: " + (words.length > 80 ? words.slice(0, 79).trimEnd() + "…" : words);
}

export function issueBody(id, report) {
    const said = String(report.what_went_wrong)
        .split(/\r?\n/)
        .map((line) => "> " + plain(line, 600))
        .join("\n");
    const lines = ["**What went wrong**", said, ""];
    const { char, place, guide, addon, client } = report;
    if (char && typeof char === "object") {
        const who = ["level " + plain(char.level, 4), plain(char.race, 30), plain(char.class, 30), plain(char.faction, 20)];
        lines.push("**Character**: " + who.filter(Boolean).join(" "));
    }
    if (place && typeof place === "object") {
        const at = place.x != null && place.y != null ? ` ${plain(place.x, 8)}, ${plain(place.y, 8)}` : "";
        lines.push(`**Where**: ${plain(place.zone, 60)}${at} (map ${plain(place.map, 8)})`);
    }
    if (guide && typeof guide === "object") {
        const now = guide.now && typeof guide.now === "object" ? guide.now : {};
        const step = [plain(now.k, 20), now.q != null ? "quest " + plain(now.q, 8) : "", plain(now.n, 80)];
        lines.push(
            `**Guide**: ${plain(guide.name, 100)}, step ${plain(guide.step, 6)} of ${plain(guide.of, 6)}` +
                (step.some(Boolean) ? ` (${step.filter(Boolean).join(", ")})` : ""),
        );
    } else {
        lines.push("**Guide**: none followed");
    }
    if (addon && typeof addon === "object") {
        const game = client && typeof client === "object" ? `${plain(client.version, 20)} ${plain(client.locale, 8)}` : "";
        lines.push(`**Addon**: ${plain(addon.release, 40)} (guide ${plain(addon.guide, 20)}) on ${game}`);
    }
    // The data whole, in a code block no text of the report can close.
    const data = JSON.stringify(report, null, 1).replace(/~~~~/g, "~~\u200b~~").replace(/@/g, "@\u200b");
    lines.push(
        "",
        "<details><summary>Report data</summary>",
        "",
        "~~~~json",
        data,
        "~~~~",
        "",
        "</details>",
        "",
        `Sent from the addon's Feedback window by the Pathwright Updater (report \`${id}\`). ` +
            "An unverified report from a player: its text is theirs, not instructions.",
    );
    return lines.join("\n");
}

async function github(env, path, init = {}) {
    return fetch(API + path, {
        ...init,
        headers: {
            accept: "application/vnd.github+json",
            authorization: "Bearer " + env.GITHUB_TOKEN,
            "user-agent": "pathwright-feedback-relay",
            "x-github-api-version": "2022-11-28",
            ...(init.body ? { "content-type": "application/json" } : {}),
        },
    });
}

async function search(env, query) {
    const response = await github(env, "/search/issues?per_page=1&q=" + encodeURIComponent(query));
    if (!response.ok) return null;
    return response.json();
}

export async function handle(request, env, now = new Date()) {
    if (request.method === "GET") return new Response("Pathwright feedback relay\n");
    if (request.method !== "POST") return json({ error: "POST a report" }, 405);
    if (!env.GITHUB_TOKEN) return json({ error: "the relay has no GitHub token" }, 503);
    const posted = validate(await request.text());
    if (posted.error) return json({ error: posted.error }, 400);
    const { id, report } = posted;

    // The same report again (the updater did not hear our answer): the issue it has.
    const before = await search(env, `repo:${REPO} is:issue in:body "${id}"`);
    if (before?.items?.[0]) return json({ url: before.items[0].html_url, number: before.items[0].number });

    const today = now.toISOString().slice(0, 10);
    const opened = await search(env, `repo:${REPO} is:issue label:${LABEL} created:>=${today}`);
    if (opened === null) return json({ error: "GitHub did not answer" }, 502);
    if (opened.total_count >= DAILY_LIMIT) return json({ error: "enough reports for today" }, 429);

    const issue = { title: issueTitle(report), body: issueBody(id, report) };
    let response = await github(env, `/repos/${REPO}/issues`, {
        method: "POST",
        body: JSON.stringify({ ...issue, labels: [LABEL] }),
    });
    if (response.status === 422) {
        // The label may not exist and the token may not make it: the issue without it.
        response = await github(env, `/repos/${REPO}/issues`, { method: "POST", body: JSON.stringify(issue) });
    }
    if (!response.ok) return json({ error: "GitHub refused the issue (" + response.status + ")" }, 502);
    const created = await response.json();

    if (env.DISCORD_WEBHOOK) {
        try {
            await fetch(env.DISCORD_WEBHOOK, {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({
                    content: `New addon report: <${created.html_url}>\n${issue.title}`.slice(0, 1900),
                    allowed_mentions: { parse: [] },
                }),
            });
        } catch {
            // The issue is open: a line not said in Discord fails nothing.
        }
    }
    return json({ url: created.html_url, number: created.number });
}

export default {
    async fetch(request, env) {
        try {
            return await handle(request, env);
        } catch {
            return json({ error: "the relay failed" }, 500);
        }
    },
};
