"""Run: python3 -m unittest discover -s scripts/tests"""
import importlib.util
import os
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location(
    "update_appcast", os.path.join(os.path.dirname(__file__), "..", "update-appcast.py"))
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)
s = appcast.s


class UpdateAppcastTests(unittest.TestCase):
    def setUp(self):
        self.path = os.path.join(tempfile.mkdtemp(), "appcast.xml")

    def add(self, version, build):
        appcast.update(self.path, version, build, f"https://x/Veya-{version}.dmg", "sig==", "123", "- Fixed")

    def items(self):
        return ET.parse(self.path).getroot().find("channel").findall("item")

    def test_creates_feed_with_signed_enclosure_and_markdown_notes(self):
        self.add("1.0.0", "10")
        [item] = self.items()
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get(s("edSignature")), "sig==")
        self.assertEqual(enclosure.get("length"), "123")
        self.assertEqual(item.findtext(s("version")), "10")
        self.assertEqual(item.find("description").get(s("format")), "markdown")
        self.assertEqual(item.findtext("description"), "- Fixed")
        self.assertIsNone(item.find(s("channel")))

    def test_prerelease_goes_on_beta_channel(self):
        self.add("1.1.0-beta.1", "11")
        self.assertEqual(self.items()[0].findtext(s("channel")), "beta")

    def test_newest_first_and_rerun_replaces(self):
        self.add("1.0.0", "10")
        self.add("1.1.0", "11")
        self.add("1.1.0", "11")
        self.assertEqual([i.findtext(s("version")) for i in self.items()], ["11", "10"])


if __name__ == "__main__":
    unittest.main()
