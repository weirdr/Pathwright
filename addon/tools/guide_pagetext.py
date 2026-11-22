import re, sys, html
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
t = re.sub(r"<script.*?</script>|<style.*?</style>|<nav.*?</nav>|<header.*?</header>|<footer.*?</footer>", "", s, flags=re.S)
t = re.sub(r"<(br|p|div|li|h\d|tr)[^>]*>", "\n", t)
t = html.unescape(re.sub(r"<[^>]+>", " ", t))
lines = [re.sub(r"[ \t]+", " ", l).strip() for l in t.split("\n")]
lines = [l for l in lines if l]
start = next((i for i, l in enumerate(lines) if l.startswith("Lv")), 0)
print("\n".join(lines[start:start + int(sys.argv[2]) if len(sys.argv) > 2 else start + 80]))
