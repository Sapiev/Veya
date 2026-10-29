#!/usr/bin/env python3
"""Adds one release to the Sparkle appcast, creating the feed if needed.

Usage: scripts/update-appcast.py <appcast.xml> <version> <build> <dmg-url> <signature> <length> <notes.md>
       scripts/update-appcast.py --check-build <appcast.xml> <build>

--check-build exits non-zero when the feed already offers a higher build, which
Sparkle would never upgrade to (a hotfix cut from a shorter branch).

A prerelease version (1.2.0-beta.1) goes on the "beta" channel, which only
apps with Include beta versions on see. Rerunning for the same build replaces
its item, so a retried release workflow does not duplicate it.
"""
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
MINIMUM_SYSTEM_VERSION = "14.0"


def s(name):
    return f"{{{SPARKLE}}}{name}"


def check_build(appcast, build):
    try:
        channel = ET.parse(appcast).getroot().find("channel")
    except FileNotFoundError:
        return
    highest = max((int(i.findtext(s("version"))) for i in channel.findall("item")), default=0)
    if int(build) < highest:
        sys.exit(f"error: build {build} is lower than build {highest} already in the appcast")


def update(appcast, version, build, url, signature, length, notes):
    try:
        tree = ET.parse(appcast)
    except FileNotFoundError:
        rss = ET.Element("rss", {"version": "2.0"})
        ET.SubElement(ET.SubElement(rss, "channel"), "title").text = "Veya"
        tree = ET.ElementTree(rss)
    channel = tree.getroot().find("channel")

    for old in channel.findall("item"):
        if old.findtext(s("version")) == build:
            channel.remove(old)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
    ET.SubElement(item, s("version")).text = build
    ET.SubElement(item, s("shortVersionString")).text = version
    ET.SubElement(item, s("minimumSystemVersion")).text = MINIMUM_SYSTEM_VERSION
    if "-" in version:
        ET.SubElement(item, s("channel")).text = "beta"
    ET.SubElement(item, "description", {s("format"): "markdown"}).text = notes
    ET.SubElement(item, "enclosure", {
        "url": url,
        "length": length,
        "type": "application/octet-stream",
        s("edSignature"): signature,
    })
    # Newest first, after the channel's own elements.
    first = next((i for i, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first, item)

    ET.indent(tree)
    tree.write(appcast, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--check-build":
        check_build(sys.argv[2], sys.argv[3])
        sys.exit(0)
    if len(sys.argv) != 8:
        sys.exit(__doc__)
    appcast, version, build, url, signature, length, notes_path = sys.argv[1:]
    with open(notes_path, encoding="utf-8") as f:
        update(appcast, version, build, url, signature, length, f.read())
