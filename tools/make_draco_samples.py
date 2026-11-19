#!/usr/bin/env python3
"""Packs downloaded Khronos glTF sample models into .glb files for the Draco
tests and the Models example. Nothing is generated: the meshes are the
samples' own bytes, only moved from a .gltf + .bin pair into one .glb.

    python3 tools/make_draco_samples.py <glTF-Sample-Assets>/Models

reads <Models>/Avocado/glTF-Draco and <Models>/Avocado/glTF (Avocado:
Microsoft, CC0 1.0, https://github.com/KhronosGroup/glTF-Sample-Assets) and
writes

  packages/threeas/tests/fixtures/avocado_draco.glb   the Draco variant
  packages/threeas/tests/fixtures/avocado.glb         the uncompressed one
      (their images stay external uris, absent: the tests read geometry)
  packages/gallery/examples/models/avocado_draco.glb  the Draco variant
      with its three textures embedded, downscaled to 512 px (macOS sips)

Both variants name their buffer "Avocado.bin", so they cannot sit side by
side as .gltf files resolving buffers by blob name; a .glb has none to
resolve. Box (CC BY 4.0, Cesium) is used as .gltf + .bin as downloaded (only
the .gltf files renamed apart): see packages/threeas/tests/draco_test.as.
"""
import json, os, struct, subprocess, sys, tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
FIXTURES = os.path.join(ROOT, "packages", "threeas", "tests", "fixtures")
MODELS = os.path.join(ROOT, "packages", "gallery", "examples", "models")


def pad(data, fill):
    return data + fill * ((4 - len(data) % 4) % 4)


def write_glb(path, gltf, bin_data):
    js = pad(json.dumps(gltf, separators=(",", ":")).encode("utf-8"), b" ")
    bn = pad(bin_data, b"\0")
    total = 12 + 8 + len(js) + 8 + len(bn)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        f.write(struct.pack("<II", len(bn), 0x004E4942) + bn)
    print("wrote", os.path.relpath(path, ROOT), total, "bytes")


def pack(folder, name, embed_images=0):
    """The .gltf in `folder` with its one buffer as the GLB chunk; images
    embedded (downscaled to `embed_images` px) when asked."""
    with open(os.path.join(folder, name + ".gltf"), "rb") as f:
        gltf = json.load(f)
    assert len(gltf["buffers"]) == 1, "one buffer expected"
    with open(os.path.join(folder, gltf["buffers"][0]["uri"]), "rb") as f:
        bin_data = bytearray(f.read())
    del gltf["buffers"][0]["uri"]
    if embed_images:
        with tempfile.TemporaryDirectory() as tmp:
            for image in gltf.get("images", []):
                src = os.path.join(folder, image["uri"])
                dst = os.path.join(tmp, os.path.basename(image["uri"]))
                subprocess.run(["sips", "-Z", str(embed_images), src, "--out", dst],
                               check=True, capture_output=True)
                with open(dst, "rb") as f:
                    png = f.read()
                while len(bin_data) % 4:
                    bin_data.append(0)
                gltf["bufferViews"].append({"buffer": 0, "byteOffset": len(bin_data), "byteLength": len(png)})
                bin_data += png
                del image["uri"]
                image["bufferView"] = len(gltf["bufferViews"]) - 1
                image["mimeType"] = "image/png"
    while len(bin_data) % 4:
        bin_data.append(0)
    gltf["buffers"][0]["byteLength"] = len(bin_data)
    return gltf, bytes(bin_data)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    models = sys.argv[1]
    for model, stem in SAMPLES:
        folder = os.path.join(models, model)
        write_glb(os.path.join(FIXTURES, stem + "_draco.glb"), *pack(os.path.join(folder, "glTF-Draco"), model))
        write_glb(os.path.join(FIXTURES, stem + ".glb"), *pack(os.path.join(folder, "glTF"), model))
    avocado = os.path.join(models, "Avocado")
    write_glb(os.path.join(MODELS, "avocado_draco.glb"),
              *pack(os.path.join(avocado, "glTF-Draco"), "Avocado", embed_images=512))


# (model, fixture stem): each model's glTF-Draco and glTF variants.
SAMPLES = [
    ("Avocado", "avocado"),             # CC0: standard Edgebreaker, uvs, normals, tangents
    ("WaterBottle", "water_bottle"),    # CC0: valence Edgebreaker (4510 triangles)
    ("RiggedSimple", "rigged_simple"),  # CC BY 4.0, Cesium: JOINTS_0 (uint16) and WEIGHTS_0
]


if __name__ == "__main__":
    main()
