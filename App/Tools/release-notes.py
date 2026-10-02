#!/usr/bin/env python3
"""release-notes.py <version>: the release's stories from Sources/IhatecryptoApp/WhatsNew/whatsnew.json as the HTML that
Sparkle's update window shows (release.sh embeds it in the appcast). Exits 1 when the version has no entry."""
import html, json, os, sys

here = os.path.dirname(os.path.abspath(__file__))
releases = json.load(open(os.path.join(here, "..", "Sources", "IhatecryptoApp", "WhatsNew", "whatsnew.json")))
release = next((r for r in releases if r["version"] == sys.argv[1]), None)
if not release:
    sys.exit(1)
print(f"<h2>What's new in {html.escape(release['version'])}</h2>\n<ul>")
for s in release["stories"]:
    print(f"  <li><b>{html.escape(s['title'])}.</b> {html.escape(s['text'])}</li>")
print("</ul>")
