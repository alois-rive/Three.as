#!/usr/bin/env python3
"""Compiles every GLSL ES 3.0 shader baked into a published .riv with
glslangValidator, as WebGL2 will (`rive <dir> --verify` does not compile the
GL backend's output). Catches what only fails in browsers, such as a WGSL
identifier the GL backend turns into a reserved `gl_` name.

Check a release build of the gallery, which holds every engine shader and
the examples' own (tools/bench.sh and tools/publish.sh build one from a
copy without the push binding, as a local --publish counts against the
bound file's workspace):

    rive packages/gallery --publish --output-dir=build/release
    python3 tools/check_glsl.py build/release/three_as.riv
"""
import os, re, shutil, subprocess, sys, tempfile

def main(path):
    if shutil.which("glslangValidator") is None:
        sys.exit("glslangValidator not found (brew install glslang)")
    data = open(path, "rb").read()
    tmp = tempfile.mkdtemp()
    failures = 0
    count = 0
    for m in re.finditer(rb"#version 300 es", data):
        end = m.start()
        while end < len(data) and (32 <= data[end] < 127 or data[end] in (9, 10, 13)):
            end += 1
        src = data[m.start():end].decode("ascii")
        stage = "vert" if "gl_Position" in src else "frag"
        f = os.path.join(tmp, "s%03d.%s" % (count, stage))
        open(f, "w").write(src)
        count += 1
        r = subprocess.run(["glslangValidator", f], capture_output=True, text=True)
        errors = [l for l in r.stdout.splitlines() if "ERROR" in l]
        if errors:
            failures += 1
            print("== shader %d (%s)" % (count - 1, stage))
            print("\n".join(errors[:5]))
    shutil.rmtree(tmp)
    print("%d GLSL shaders, %d failing" % (count, failures))
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
