#!/usr/bin/env python3
"""Insert (or replace) a release item in appcast.xml for Sparkle.

Usage:
    update-appcast.py <version> <build> <edSignature> <length> <notes> <dmg-url> <min-system>

The appcast lives at the repository root and is served to installed apps via
raw.githubusercontent.com; Scripts/release.sh calls this after creating the
GitHub release so the DMG is downloadable before the item goes live.
"""
import email.utils
import os
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
APPCAST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "appcast.xml")


def main() -> int:
    try:
        version, build, signature, length, notes, dmg_url, min_system = sys.argv[1:8]
    except ValueError:
        print(__doc__, file=sys.stderr)
        return 2

    ET.register_namespace("sparkle", SPARKLE_NS)
    ET.register_namespace("dc", DC_NS)
    tree = ET.parse(APPCAST)
    channel = tree.getroot().find("channel")
    if channel is None:
        print("appcast.xml has no <channel>", file=sys.stderr)
        return 1

    def sparkle(tag: str) -> str:
        return f"{{{SPARKLE_NS}}}{tag}"

    # Drop a stale item for the same release (re-running the release script).
    for old in list(channel.findall("item")):
        if old.findtext(sparkle("version")) == build or old.findtext(sparkle("shortVersionString")) == version:
            channel.remove(old)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"AwakeKit {version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, sparkle("version")).text = build
    ET.SubElement(item, sparkle("shortVersionString")).text = version
    ET.SubElement(item, sparkle("os")).text = "macos"
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", dmg_url)
    enclosure.set("type", "application/x-bzip2")
    enclosure.set("length", length)
    enclosure.set(sparkle("edSignature"), signature)
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = min_system
    ET.SubElement(item, "description").text = notes

    # Newest item first: before the first existing <item>, or at the end of
    # the channel metadata when this is the first release.
    existing = channel.findall("item")
    if existing:
        index = list(channel).index(existing[0])
    else:
        index = len(list(channel))
    channel.insert(index, item)

    ET.indent(tree, space="  ")
    with open(APPCAST, "w", encoding="utf-8") as f:
        f.write(ET.tostring(tree.getroot(), encoding="unicode", xml_declaration=True))
        f.write("\n")
    print(f"appcast.xml: added item for {version} (build {build})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
