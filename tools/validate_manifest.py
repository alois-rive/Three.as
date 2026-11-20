#!/usr/bin/env python3
"""Checks `rive --gpu-manifest` output (the WebGPU descriptors scripts
create) against WebGPU's validation rules and the limits ThreeAS targets,
since Rive's own validator (tools/webgpu_validate, which the CLI help names)
is not shipped with the CLI.

    python3 tools/validate_manifest.py build/manifest.json [more.json ...]
    python3 tools/validate_manifest.py --all     # every example artboard and the
                                                 # Gallery of packages/gallery, into
                                                 # packages/gallery/build/manifests/
    python3 tools/validate_manifest.py --all --gallery=DIR   # another gallery checkout

What it checks (descriptor sanity, not a GPU):
  layouts     bindings 0-7 (Rive), unique; uniform minBindingSize <= 16 KB
              (WebGL2 UBOs) and <= 64 KB (WebGPU)
  pipelines   <= 4 bind groups (Rive and WebGPU); per stage <= 16 sampled
              textures (the web's limit, every binding the layouts declare
              for the stage), <= 16 samplers, <= 12 uniform buffers, <= 8
              dynamic uniform buffers; <= 8 vertex buffers (Rive), <= 16
              attributes, unique locations < 16, strides and offsets
              4-aligned within the stride and <= 2048; every @location the
              vertex entry point reads supplied by a buffer; <= 8 colour
              targets; sample count 1 or 4; the depth/stencil state present
              for a depth format
  bind groups every layout binding filled, none extra; buffer ranges in
              bounds and at least minBindingSize; texture view dimension,
              multisampling and sample type (depth / float) as the layout
              says; comparison samplers where the layout wants them,
              nearest-only samplers for non-filtering slots
  shaders     no identifier `gl` or `gl_...` (WebGL2 reserves them); no
              @builtin(instance_index) (naga emulates it on WebGL2 with the
              plain uniform naga_vs_first_instance, which Rive's web runtime
              fails to query: see tools/check_glsl.py)

Not checked (no data in the manifest, or needs a GPU): dynamic offsets at
draw time (256-byte alignment), textures written and sampled in one pass,
resource usage flags, formats' filterability per device, timing.
"""
import glob
import json
import os
import re
import subprocess
import sys

MAX_BINDING = 7
MAX_GROUPS = 4
MAX_TEXTURES_PER_STAGE = 16
MAX_SAMPLERS_PER_STAGE = 16
MAX_UNIFORM_BUFFERS_PER_STAGE = 12
MAX_DYNAMIC_UNIFORM = 8
MAX_VERTEX_BUFFERS = 8
MAX_VERTEX_ATTRIBUTES = 16
MAX_UNIFORM_WEBGL2 = 16384
MAX_UNIFORM_WEBGPU = 65536
MAX_COLOR_TARGETS = 8
STAGES = (("vertex", 1), ("fragment", 2))
FORMAT_SIZES = {"float32": 4, "float32x2": 8, "float32x3": 12, "float32x4": 16, "uint32": 4, "uint32x2": 8,
                "uint32x3": 12, "uint32x4": 16, "sint32": 4, "sint32x2": 8, "sint32x3": 12, "sint32x4": 16,
                "float16x2": 4, "float16x4": 8, "unorm8x4": 4, "snorm8x4": 4, "uint8x4": 4, "unorm16x2": 4,
                "unorm16x4": 8, "uint16x2": 4, "uint16x4": 8}
DEPTH_FORMATS = {"depth16unorm", "depth24plus", "depth24plus-stencil8", "depth32float", "depth32float-stencil8"}
# Formats WebGPU cannot filter without a feature: bound only to unfilterable slots.
UNFILTERABLE = {"rgba32float", "rg32float", "r32float", "rgba32uint", "rgba32sint", "r32uint", "r32sint"}


def check(path):
    m = json.load(open(path))
    problems = []
    layouts = {l["id"]: l for l in m.get("bindGroupLayouts", [])}
    shaders = m.get("shaders", {})

    for l in layouts.values():
        seen = set()
        for e in l["entries"]:
            b = e["binding"]
            where = f"layout {l['id']} (group {l['group']}) binding {b}"
            if b < 0 or b > MAX_BINDING:
                problems.append(f"{where}: binding beyond 0-{MAX_BINDING} (Rive)")
            if b in seen:
                problems.append(f"{where}: declared twice")
            seen.add(b)
            buf = e.get("buffer")
            if buf and buf.get("type") == "uniform":
                size = buf.get("minBindingSize", 0)
                if size > MAX_UNIFORM_WEBGPU:
                    problems.append(f"{where}: uniform block of {size} bytes > {MAX_UNIFORM_WEBGPU}")
                elif size > MAX_UNIFORM_WEBGL2:
                    problems.append(f"{where}: uniform block of {size} bytes > {MAX_UNIFORM_WEBGL2} (WebGL2)")

    for i, p in enumerate(m.get("pipelines", [])):
        label = f"pipeline {i} ({p['vertex'].get('label', '')} {p['vertex']['entryPoint']}" \
                f"/{p.get('fragment', {}).get('entryPoint', '-')})"
        ids = p.get("layout", [])
        if len(ids) > MAX_GROUPS:
            problems.append(f"{label}: {len(ids)} bind groups > {MAX_GROUPS}")
        entries = []
        for lid in ids:
            if lid not in layouts:
                problems.append(f"{label}: unknown layout {lid}")
                continue
            entries.extend(layouts[lid]["entries"])
        dynamic = sum(1 for e in entries if e.get("buffer", {}).get("hasDynamicOffset"))
        if dynamic > MAX_DYNAMIC_UNIFORM:
            problems.append(f"{label}: {dynamic} dynamic uniform buffers > {MAX_DYNAMIC_UNIFORM}")
        for stage, bit in STAGES:
            visible = [e for e in entries if e.get("visibility", 7) & bit]
            textures = sum(1 for e in visible if "texture" in e)
            samplers = sum(1 for e in visible if "sampler" in e)
            uniforms = sum(1 for e in visible if e.get("buffer", {}).get("type") == "uniform")
            if textures > MAX_TEXTURES_PER_STAGE:
                problems.append(f"{label}: {textures} textures in the {stage} stage > {MAX_TEXTURES_PER_STAGE} (web)")
            if samplers > MAX_SAMPLERS_PER_STAGE:
                problems.append(f"{label}: {samplers} samplers in the {stage} stage > {MAX_SAMPLERS_PER_STAGE}")
            if uniforms > MAX_UNIFORM_BUFFERS_PER_STAGE:
                problems.append(f"{label}: {uniforms} uniform buffers in the {stage} stage"
                                f" > {MAX_UNIFORM_BUFFERS_PER_STAGE}")
        buffers = p["vertex"].get("buffers", [])
        if len(buffers) > MAX_VERTEX_BUFFERS:
            problems.append(f"{label}: {len(buffers)} vertex buffers > {MAX_VERTEX_BUFFERS} (Rive)")
        locations = set()
        attributes = 0
        for k, vb in enumerate(buffers):
            stride = vb.get("arrayStride", 0)
            if stride % 4 or stride > 2048:
                problems.append(f"{label}: buffer {k} stride {stride} not 4-aligned or > 2048")
            for a in vb.get("attributes", []):
                attributes += 1
                size = FORMAT_SIZES.get(a["format"], 4)
                off = a["offset"]
                if off % min(4, size):
                    problems.append(f"{label}: buffer {k} attribute at {off} misaligned")
                if stride and off + size > stride:
                    problems.append(f"{label}: buffer {k} attribute at {off} ({a['format']}) past stride {stride}")
                loc = a["shaderLocation"]
                if loc >= MAX_VERTEX_ATTRIBUTES or loc in locations:
                    problems.append(f"{label}: location {loc} out of range or repeated")
                locations.add(loc)
        if attributes > MAX_VERTEX_ATTRIBUTES:
            problems.append(f"{label}: {attributes} attributes > {MAX_VERTEX_ATTRIBUTES}")
        module = shaders.get(str(p["vertex"]["module"]))
        if module is not None:
            missing = sorted(set(entry_locations(module["code"], p["vertex"]["entryPoint"])) - locations)
            if missing:
                problems.append(f"{label}: the vertex stage reads locations {missing} no buffer supplies")
        frag = p.get("fragment")
        if frag is not None and len(frag.get("targets", [])) > MAX_COLOR_TARGETS:
            problems.append(f"{label}: {len(frag['targets'])} colour targets > {MAX_COLOR_TARGETS}")
        count = p.get("multisample", {}).get("count", 1)
        if count not in (1, 4):
            problems.append(f"{label}: sample count {count} (WebGPU: 1 or 4)")
        ds = p.get("depthStencil")
        if ds is not None and ds.get("format") not in DEPTH_FORMATS:
            problems.append(f"{label}: depth/stencil format {ds.get('format')}")

    for i, g in enumerate(m.get("bindGroups", [])):
        layout = layouts.get(g["layout"])
        if layout is None:
            problems.append(f"bind group {i}: unknown layout {g['layout']}")
            continue
        want = {e["binding"]: e for e in layout["entries"]}
        have = {e["binding"]: e for e in g["entries"]}
        where = f"bind group {i} (layout {layout['id']}, group {layout['group']})"
        for b in sorted(set(want) - set(have)):
            problems.append(f"{where}: binding {b} not filled")
        for b in sorted(set(have) - set(want)):
            problems.append(f"{where}: binding {b} not in the layout")
        for b, e in have.items():
            w = want.get(b)
            if w is None:
                continue
            if "buffer" in w:
                buf = e.get("buffer")
                if buf is None:
                    problems.append(f"{where} binding {b}: a buffer slot given no buffer")
                    continue
                total, off, size = buf["bufferSize"], buf["offset"], buf["size"]
                span = size if size else total - off
                if off + span > total:
                    problems.append(f"{where} binding {b}: range {off}+{span} past the buffer's {total} bytes")
                if span < w["buffer"].get("minBindingSize", 0):
                    problems.append(f"{where} binding {b}: {span} bytes bound < the shader's"
                                    f" {w['buffer']['minBindingSize']}")
                if buf.get("usage") == "uniform" and span > MAX_UNIFORM_WEBGPU:
                    problems.append(f"{where} binding {b}: uniform range of {span} bytes > {MAX_UNIFORM_WEBGPU}")
            elif "texture" in w:
                t, v = e.get("texture"), e.get("view", {})
                if t is None:
                    problems.append(f"{where} binding {b}: a texture slot given no texture")
                    continue
                lt = w["texture"]
                if v.get("dimension", "2d") != lt.get("viewDimension", "2d"):
                    problems.append(f"{where} binding {b}: view {v.get('dimension')} where the layout wants"
                                    f" {lt.get('viewDimension')}")
                if (t.get("sampleCount", 1) > 1) != bool(lt.get("multisampled")):
                    problems.append(f"{where} binding {b}: multisampling differs from the layout")
                depth = t["format"] in DEPTH_FORMATS and v.get("aspect", "all") != "stencil-only"
                if lt.get("sampleType") == "depth" and not depth:
                    problems.append(f"{where} binding {b}: {t['format']} in a depth slot")
                if lt.get("sampleType") == "float" and depth:
                    problems.append(f"{where} binding {b}: depth texture {t['format']} in a float slot")
                if lt.get("sampleType") == "float" and t["format"] in UNFILTERABLE:
                    problems.append(f"{where} binding {b}: {t['format']} is not filterable (float slot)")
            elif "sampler" in w:
                s = e.get("sampler")
                if s is None:
                    problems.append(f"{where} binding {b}: a sampler slot given no sampler")
                    continue
                kind = w["sampler"].get("type", "filtering")
                if (kind == "comparison") != bool(s.get("comparison")):
                    problems.append(f"{where} binding {b}: comparison sampler mismatch")
                if kind == "non-filtering" and s.get("filter") != "nearest":
                    problems.append(f"{where} binding {b}: a filtering sampler in a non-filtering slot")

    for sid, s in shaders.items():
        for ident in sorted(set(re.findall(r"\b(gl(?:_\w*)?)\b", s.get("code", "")))):
            problems.append(f"shader {s.get('label', sid)}: identifier `{ident}` is reserved in WebGL2")
        if re.search(r"@builtin\s*\(\s*instance_index\s*\)", s.get("code", "")):
            problems.append(f"shader {s.get('label', sid)}: @builtin(instance_index) becomes the uniform "
                            "naga_vs_first_instance on WebGL2, which crashes Rive's web runtime; "
                            "use a per-instance vertex attribute")

    stats = (len(layouts), len(m.get("pipelines", [])), len(m.get("bindGroups", [])), len(shaders),
             len(m.get("skipped", [])))
    return problems, stats


def entry_locations(code, entry):
    """The @location inputs an entry point reads (its parameters and the
    structs they are), from the WGSL the manifest holds."""
    sig = re.search(r"fn\s+%s\s*\((.*?)\)\s*(->|\{)" % re.escape(entry), code, re.S)
    if not sig:
        return []
    out = []
    for param in split_params(sig.group(1)):
        m = re.search(r"@location\((\d+)\)", param)
        if m:
            out.append(int(m.group(1)))
            continue
        t = re.search(r":\s*([A-Za-z_]\w*)\s*$", param.strip())
        if not t:
            continue
        struct = re.search(r"struct\s+%s\s*\{(.*?)\}" % re.escape(t.group(1)), code, re.S)
        if struct:
            out.extend(int(x) for x in re.findall(r"@location\((\d+)\)", struct.group(1)))
    return out


def split_params(text):
    parts, depth, cur = [], 0, ""
    for ch in text:
        if ch in "(<":
            depth += 1
        elif ch in ")>":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def capture_all(root):
    out = os.path.join(root, "build", "manifests")
    os.makedirs(out, exist_ok=True)
    rml = "".join(open(p).read() for p in sorted(glob.glob(os.path.join(root, "examples", "*", "*.rml"))))
    names = re.findall(r'<Artboard isComponent="true"[^>]*name="([^"]*)"', rml) + ["Gallery"]
    paths = []
    for name in names:
        path = os.path.join(out, name + ".json")
        shot = os.path.join(out, name + ".png")
        r = subprocess.run(["rive", root, f"--artboard={name}", f"--gpu-manifest={path}", f"--screenshot={shot}",
                            "--advance=1s"], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(path):
            print(f"{name}: rive failed\n{r.stdout[-2000:]}{r.stderr[-2000:]}")
            continue
        paths.append(path)
    return paths


def main(args):
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packages", "gallery")
    for a in [a for a in args if a.startswith("--gallery=")]:
        root = a[len("--gallery="):]
        args.remove(a)
    paths = capture_all(root) if args == ["--all"] else args
    if not paths:
        print(__doc__)
        return 2
    failed = 0
    for path in paths:
        problems, (nl, np_, ng, ns, skipped) = check(path)
        name = os.path.splitext(os.path.basename(path))[0]
        status = "ok" if not problems else f"{len(problems)} problem(s)"
        extra = f", {skipped} skipped" if skipped else ""
        print(f"{name}: {np_} pipelines, {nl} layouts, {ng} bind groups, {ns} shaders{extra}: {status}")
        for p in problems[:20]:
            print("    " + p)
        if len(problems) > 20:
            print(f"    ... {len(problems) - 20} more")
        failed += bool(problems)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
