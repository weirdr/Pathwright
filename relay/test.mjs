// Tests of the feedback relay, with GitHub played by a stub: node relay/test.mjs
import assert from "node:assert/strict";
import { DAILY_LIMIT, handle, issueBody, issueTitle, plain, validate } from "./worker.js";

const report = {
    report: "pathwright-feedback",
    v: 1,
    what_went_wrong: "The scouts are not at the marker @everyone\n<img src=x> ``` ~~~~",
    addon: { release: "Pathwright-v1.0.28", guide: "0.21.0" },
    client: { version: "1.60.1", locale: "enUS" },
    char: { level: 34, class: "HUNTER", race: "Troll", faction: "Horde" },
    place: { zone: "Stranglethorn Vale", map: 1434, x: 38.2, y: 51 },
    guide: { name: "Stranglethorn (30-36)", step: 41, of: 212, now: { k: "objective", q: 582, n: "Bloodscalp Scout" } },
    quests: [[582, 0, [[3, 8]]]],
};
const id = "1795491613-cb51";
const post = (body) => new Request("https://relay.example/", { method: "POST", body });

// What is taken as a report.
assert.deepEqual(validate(JSON.stringify({ id, report })), { id, report });
assert.equal(validate("{").error, "not JSON");
assert.equal(validate(JSON.stringify({ id: "x y", report })).error, "no report id");
assert.equal(validate(JSON.stringify({ id, report: { ...report, report: "other" } })).error, "not a feedback report");
assert.equal(validate(JSON.stringify({ id, report: { ...report, what_went_wrong: " " } })).error, "nothing said");
assert.equal(validate("x".repeat(30000)).error, "too large");

// What a stranger wrote cannot ping, mark up or close the data's block.
assert.equal(plain("@weirdr <b>*hi*</b>"), "@\u200bweirdr &lt;b&gt;\\*hi\\*&lt;/b&gt;");
assert.equal(issueTitle(report), "Feedback: The scouts are not at the marker @\u200beveryone");
assert.ok(issueTitle({ what_went_wrong: "x".repeat(200) }).length <= 90);
const body = issueBody(id, report);
assert.ok(body.startsWith("**What went wrong**\n> The scouts are not at the marker @\u200beveryone\n> &lt;img"));
assert.ok(body.includes("**Guide**: Stranglethorn (30-36), step 41 of 212 (objective, quest 582, Bloodscalp Scout)"));
assert.ok(body.includes("**Character**: level 34 Troll HUNTER Horde"));
assert.ok(body.includes("report `1795491613-cb51`"));
assert.equal(body.split("~~~~").length, 3, "one code block, opened and closed once");
assert.ok(!/(^|[^\u200b])@everyone/.test(body), "no mention left as one");

// The whole way, GitHub played by a stub.
const calls = [];
let found = [];
let openedToday = 0;
let createStatus = [201];
globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    const answer = (value, status = 200) => new Response(JSON.stringify(value), { status });
    if (String(url).includes("/search/issues")) {
        const query = decodeURIComponent(String(url).split("q=")[1]);
        return query.includes("in:body") ? answer({ items: found }) : answer({ total_count: openedToday, items: [] });
    }
    if (String(url).endsWith("/issues")) {
        const status = createStatus.shift() ?? 201;
        return status === 201
            ? answer({ html_url: "https://github.com/weirdr/Pathwright/issues/12", number: 12 }, 201)
            : answer({ message: "no" }, status);
    }
    return answer({});
};
const env = { GITHUB_TOKEN: "token", DISCORD_WEBHOOK: "https://discord.example/hook" };
const now = new Date("2026-11-24T10:00:00Z");

let response = await handle(post(JSON.stringify({ id, report })), env, now);
assert.equal(response.status, 200);
assert.deepEqual(await response.json(), { url: "https://github.com/weirdr/Pathwright/issues/12", number: 12 });
const created = calls.find((c) => c.url.endsWith("/issues"));
assert.equal(created.init.headers.authorization, "Bearer token");
assert.deepEqual(JSON.parse(created.init.body).labels, ["addon-report"]);
assert.ok(calls.some((c) => c.url.includes("created%3A%3E%3D2026-11-24")), "today's reports are counted");
const said = calls.find((c) => c.url === env.DISCORD_WEBHOOK);
assert.deepEqual(JSON.parse(said.init.body).allowed_mentions, { parse: [] });

// The same report again: the issue it has, none opened.
found = [{ html_url: "https://github.com/weirdr/Pathwright/issues/12", number: 12 }];
calls.length = 0;
response = await handle(post(JSON.stringify({ id, report })), env, now);
assert.equal((await response.json()).number, 12);
assert.ok(!calls.some((c) => c.url.endsWith("/issues")), "no second issue for one report");

// Enough for today; a label GitHub does not know; no token; not a report; not a POST.
found = [];
openedToday = DAILY_LIMIT;
assert.equal((await handle(post(JSON.stringify({ id, report })), env, now)).status, 429);
openedToday = 0;
createStatus = [422, 201];
calls.length = 0;
assert.equal((await handle(post(JSON.stringify({ id, report })), env, now)).status, 200);
const tries = calls.filter((c) => c.url.endsWith("/issues"));
assert.equal(tries.length, 2);
assert.equal(JSON.parse(tries[1].init.body).labels, undefined, "the issue without the label");
createStatus = [500];
assert.equal((await handle(post(JSON.stringify({ id, report })), env, now)).status, 502);
assert.equal((await handle(post(JSON.stringify({ id, report })), {}, now)).status, 503);
assert.equal((await handle(post("nope"), env, now)).status, 400);
assert.equal((await handle(new Request("https://relay.example/", { method: "PUT" }), env, now)).status, 405);
assert.equal((await handle(new Request("https://relay.example/"), env, now)).status, 200);

console.log("relay ok");
