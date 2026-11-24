# Pathwright feedback relay

A Cloudflare Worker (`worker.js`) that turns a feedback report from the addon into a GitHub issue.

The addon's Feedback window (the speech bubble under the guide, or `/pw feedback`) asks "What went
wrong?" and makes a report of the answer and of the game at that moment. The Pathwright Updater
reads it from the addon's saved data after a reload and posts it here. The updater is a public
program and holds no secret; the GitHub token lives in this Worker.

- Each report opens one issue, labelled `addon-report`, however often it is posted.
- At most 40 issues a day are opened.
- Issues are not given the `overwatch` label: a person reads them first.
- A report holds no character or account name. Its text is a stranger's: it is quoted, mentions
  are defused, and the data sits in a code block.

## Setting it up (once)

Names in Cloudflare's dashboard change now and then; these are the places to look for.

1. **A GitHub token for it.** On GitHub: Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token. Repository access: only `weirdr/Pathwright`.
   Permissions: Issues, read and write. Nothing else. Copy the token.
2. **The label.** In the repository: Issues → Labels → New label, named `addon-report`. Without it
   the issues are still opened, only unlabelled, and the daily limit counts nothing.
3. **The Worker.** In Cloudflare: Workers & Pages → Create → Worker ("Hello World"). Name it
   `pathwright-feedback`, deploy it, then Edit code: replace everything with the contents of
   `worker.js` and deploy again.
4. **Its secret.** In the Worker: Settings → Variables and Secrets → Add. Type: Secret. Name:
   `GITHUB_TOKEN`. Value: the token from step 1. Optional, the same way: `DISCORD_WEBHOOK`, a
   Discord webhook address that gets one line for each issue opened.
5. **Its address.** The Worker's page shows it, like
   `https://pathwright-feedback.<your-subdomain>.workers.dev`. With a domain of your own in
   Cloudflare: Settings → Domains & Routes → Add → Custom domain (for example
   `feedback.<your-domain>`). Opened in a browser, the address answers "Pathwright feedback relay".
6. **Tell the updater.** Put that address in `RELAY_URL` in
   `crates/pathwright-updater/src/feedback.rs` and release the updater. Until then the updater
   sends nothing, and the addon only offers to copy the report by hand.

To stop it: delete the Worker, or its `GITHUB_TOKEN` secret (it then answers 503).

## Trying it

```sh
node relay/test.mjs
```

With the Worker deployed, a report by hand (it opens a real issue):

```sh
curl -sS https://pathwright-feedback.<your-subdomain>.workers.dev/ -H 'content-type: application/json' --data '{"id":"0000-test01","report":{"report":"pathwright-feedback","v":1,"what_went_wrong":"A test of the relay"}}'
```
