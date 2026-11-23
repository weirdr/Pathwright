#!/bin/sh
# Announce an addon release in a Discord channel: its title linking to the GitHub release, its
# notes (the changes since the release before) as the message. Called by
# .github/workflows/addon-release.yml after each release, the webhook being the repository secret
# DISCORD_RELEASE_WEBHOOK (Discord: the channel's settings, Integrations, Webhooks).
#
#   DISCORD_WEBHOOK=https://discord.com/api/webhooks/... scripts/discord-release.sh Pathwright-v1.0.2
#   scripts/discord-release.sh --print Pathwright-v1.0.2     # the message only, nothing sent
set -eu
cd "$(dirname "$0")/.."

print=false
if [ "${1:-}" = --print ]; then
    print=true
    shift
fi
tag=${1:?usage: $0 [--print] TAG}
repo=${GITHUB_REPOSITORY:-weirdr/Pathwright}

# The message: an embed (Discord's limit for its text is 4096 characters), nobody pinged by
# whatever the commit messages say.
payload=$(gh release view "$tag" --repo "$repo" --json name,url,body,publishedAt | jq '
    (.body // "" | gsub("\r"; "")) as $notes
    | {
        username: "Pathwright",
        allowed_mentions: { parse: [] },
        embeds: [{
            title: .name,
            url: .url,
            description: (if ($notes | length) > 4000 then $notes[0:4000] + "\n…" else $notes end),
            color: 3447003,
            timestamp: .publishedAt
        }]
    }')

if $print; then
    printf '%s\n' "$payload"
    exit 0
fi
: "${DISCORD_WEBHOOK:?DISCORD_WEBHOOK is not set}"
printf '%s' "$payload" | curl -fsS -o /dev/null -H 'Content-Type: application/json' --data-binary @- "$DISCORD_WEBHOOK"
echo "$tag announced in Discord"
