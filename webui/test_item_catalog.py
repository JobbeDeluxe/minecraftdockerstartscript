"""Keep the bundled picker complete and reject broken catalog updates."""
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("item_catalog", ROOT / "tools/update_item_catalog.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class ItemCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.items = json.loads((ROOT / "webui/static/items.json").read_text(encoding="utf-8"))["items"]

    def test_every_catalog_item_has_a_png(self):
        self.assertEqual(len(self.items), 1505)
        generator.validate_catalog(self.items)

    def test_missing_icon_rejects_update(self):
        item = {**self.items[0], "icon": None}
        with self.assertRaisesRegex(ValueError, item["id"]):
            generator.validate_catalog([item])

    def test_invalid_png_rejects_update(self):
        item = {**self.items[0], "icon": "data:image/png;base64,aGVsbG8="}
        with self.assertRaisesRegex(ValueError, item["id"]):
            generator.validate_catalog([item])

    def test_duplicate_id_rejects_update(self):
        with self.assertRaisesRegex(ValueError, "Duplicate item"):
            generator.validate_catalog([self.items[0], self.items[0]])

    def test_supplemental_renders_are_embedded_without_changes(self):
        overrides = generator.load_icon_overrides()["items"]
        self.assertEqual(len(overrides), 21)
        indexed = {item["id"]: item for item in self.items}
        for name, source in overrides.items():
            with self.subTest(item=name):
                item = indexed[f"minecraft:{name}"]
                self.assertEqual(item["icon"], source["icon"])
                self.assertEqual(item["iconLayout"], "contain")


if __name__ == "__main__":
    unittest.main()
