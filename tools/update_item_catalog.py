"""Rebuild the bundled, offline Java item picker from pinned upstream data."""
import base64
import json
import hashlib
from concurrent.futures import ThreadPoolExecutor
import urllib.request
from pathlib import Path

VERSION = "26.1"
DATA_REVISION = "201ca802a1b2c968b02e7fa5b31dd74e8bff3d8b"
ASSETS_REVISION = "6c571b0825ee27b81f01127c2bd0d4ba2c89abb9"
RENDER_REVISION = "36475eb8d6093597001c3c0549662b04786305ef"
RENDER_BASE = f"https://raw.githubusercontent.com/Webisso/minecraft-item-icons/{RENDER_REVISION}/public"
RENDER_CATALOG_URL = f"{RENDER_BASE}/api.json"
GERMAN_HASH = "b29f0ba4b2ce28b1b91a540d50455ecc632bfb41"
DATA_URL = f"https://raw.githubusercontent.com/PrismarineJS/minecraft-data/{DATA_REVISION}/data/pc/{VERSION}/items.json"
TEXTURES_URL = f"https://raw.githubusercontent.com/PrismarineJS/minecraft-assets/{ASSETS_REVISION}/data/{VERSION}/texture_content.json"
GERMAN_URL = f"https://resources.download.minecraft.net/{GERMAN_HASH[:2]}/{GERMAN_HASH}"


def download(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)


def render_entries(value):
    if isinstance(value, dict):
        if "file_slug" in value:
            yield value
        else:
            for child in value.values():
                yield from render_entries(child)
    elif isinstance(value, list):
        for child in value:
            yield from render_entries(child)


def download_render(entry):
    parts = [entry["category_slug"], entry.get("subcategory_slug"), entry["file_slug"]]
    url = RENDER_BASE + "/thumbnails/" + "/".join(part for part in parts if part)
    with urllib.request.urlopen(url, timeout=60) as response:
        png = response.read()
    if not png.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"Expected a PNG render: {url}")
    return "data:image/png;base64," + base64.b64encode(png).decode("ascii")


def png_bytes(icon):
    prefix = "data:image/png;base64,"
    if not isinstance(icon, str) or not icon.startswith(prefix):
        raise ValueError("Missing PNG icon")
    png = base64.b64decode(icon[len(prefix):], validate=True)
    if not png.startswith(b"\x89PNG\r\n\x1a\n") or not png.endswith(b"IEND\xaeB`\x82"):
        raise ValueError("Invalid PNG icon")
    return png


def load_icon_overrides():
    path = Path(__file__).with_name("item_icon_overrides.json")
    data = json.loads(path.read_text(encoding="utf-8"))
    for name, entry in data["items"].items():
        if hashlib.sha256(png_bytes(entry["icon"])).hexdigest() != entry["sha256"]:
            raise ValueError(f"Changed override image: {name}")
    return data


def validate_catalog(catalog):
    seen = set()
    for item in catalog:
        if item["id"] in seen:
            raise ValueError(f"Duplicate item: {item['id']}")
        seen.add(item["id"])
        try:
            png_bytes(item["icon"])
        except (ValueError, KeyError) as error:
            raise ValueError(f"Missing or invalid icon: {item['id']}") from error


def main():
    items = download(DATA_URL)
    textures = {entry["name"]: entry.get("texture") for entry in download(TEXTURES_URL)}
    german = download(GERMAN_URL)
    renders = {}
    for entry in render_entries(download(RENDER_CATALOG_URL)):
        if entry["category_slug"] in {"10-items", "20-blocks"} and entry["file_slug"].endswith(".png"):
            name = entry["file_slug"][:-4].replace("-", "_")
            renders.setdefault(name, entry)
    # Beds resolve to wooden planks in the raw texture atlas. Prefer real renders;
    # also use this second source wherever the primary catalog has no texture.
    needed = {item["name"]: renders[item["name"]] for item in items
              if item["name"] in renders
              and (item["name"].endswith("_bed") or not textures.get(item["name"]))}
    with ThreadPoolExecutor(max_workers=8) as pool:
        fallback = dict(zip(needed, pool.map(download_render, needed.values())))
    overrides = load_icon_overrides()
    fallback.update({name: entry["icon"] for name, entry in overrides["items"].items()})
    catalog = []
    for item in items:
        name = item["name"]
        if name == "air":
            continue
        icon = fallback.get(name) or textures.get(name)
        if icon and not icon.startswith("data:image/png;base64,"):
            raise ValueError(f"Unexpected texture format: {name}")
        catalog.append({"id": f"minecraft:{name}", "en": item["displayName"],
                        "de": german.get(f"item.minecraft.{name}", german.get(f"block.minecraft.{name}", item["displayName"])),
                        "icon": icon, **({"iconLayout": "contain"} if name in fallback else {})})
    # Refuse an incomplete update before replacing the previously working catalog.
    validate_catalog(catalog)
    output = {"version": VERSION, "sources": [DATA_URL, TEXTURES_URL, GERMAN_URL, RENDER_CATALOG_URL,
              *[entry["url"] for entry in overrides["items"].values()]], "items": catalog}
    path = Path(__file__).resolve().parents[1] / "webui" / "static" / "items.json"
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    temporary.replace(path)
    print(f"Added {len(fallback)} rendered fallback icons")
    print(f"Bundled {len(catalog)} items, {sum(bool(item['icon']) for item in catalog)} icons ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
