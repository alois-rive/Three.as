#!/usr/bin/env python3
"""Compiles every GLSL ES 3.0 shader baked into a published .riv with
glslangValidator, as WebGL2 will (`rive <dir> --verify` does not compile the
GL backend's output). Catches what only fails in browsers, such as a WGSL
identifier the GL backend turns into a reserved `gl_` name.

Also fails on a shadow sampler (`sampler2DShadow`, `sampler2DArrayShadow`,
`samplerCubeShadow` ...), what naga makes of a WGSL `sampler_comparison`
used with `textureSampleCompare*`. Rive's web runtime (the threaded WebGL2
one), after linking such a program, queries each of its sampler uniforms
with glGetUniformiv while no program is bound; WebGL2's getUniform then
throws ("parameter 2 is not of type 'WebGLUniformLocation'") and the render
worker dies, blanking the whole page. Read depth textures with textureLoad
and compare in the shader (three.wgsl's shadow_compare); plain depth reads
(textureLoad, or textureSampleLevel with a plain sampler) become
`sampler2D`/`sampler2DArray` and are fine.

And fails on a plain (non-block, non-sampler) uniform, such as
`uniform uint naga_vs_first_instance;`: WGSL has none, so they are the GL
translator's (naga's) emulation uniforms, `naga_vs_first_instance` for a
vertex entry point reading `@builtin(instance_index)`. A precaution: it was
suspected of the same crash, but the program that showed it also had a
comparison sampler, and it is not confirmed to crash on its own. Keep
`@builtin(instance_index)` out of shaders anyway (three.wgsl's instanced
morphs read their row from a vertex attribute instead).

Check a release build of the gallery, which holds every engine shader and
the examples' own (tools/bench.sh and tools/publish.sh build one from a
copy without the push binding, as a local --publish counts against the
bound file's workspace):

    rive packages/gallery --publish --output-dir=build/release
    python3 tools/check_glsl.py build/release/three_as.riv
"""
import os, re, shutil, subprocess, sys, tempfile

# A uniform outside a block: `uniform [precision] <type> <name>[n];`.
PLAIN_UNIFORM = re.compile(
    r"^\s*(?:layout\s*\([^)]*\)\s*)?uniform\s+(?:(?:highp|mediump|lowp)\s+)?(\w+)\s+(\w+)\s*(?:\[[^\]]*\])?\s*;",
    re.M)

# A shadow (depth comparison) sampler uniform.
SHADOW_SAMPLER = re.compile(r"^\s*uniform\s+(?:(?:highp|mediump|lowp)\s+)?(\w*sampler\w*Shadow)\s+(\w+)", re.M)

def plain_uniforms(src):
    """Plain uniforms of a GLSL source, as 'type name' (samplers excluded)."""
    return ["%s %s" % (m.group(1), m.group(2)) for m in PLAIN_UNIFORM.finditer(src)
            if "sampler" not in m.group(1) and "image" not in m.group(1)]

def main(path):
    if shutil.which("glslangValidator") is None:
        sys.exit("glslangValidator not found (brew install glslang)")
    data = open(path, "rb").read()
    tmp = tempfile.mkdtemp()
    failures = 0
    count = 0
    emulated = 0
    shadow = 0
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
        output = (r.stdout + "\n" + r.stderr).splitlines()
        errors = [l for l in output if "ERROR" in l]
        if r.returncode != 0 and not errors:
            detail = (r.stderr or r.stdout).strip()
            errors.append("glslangValidator exited %d%s" % (r.returncode, ": " + detail if detail else ""))
        plain = plain_uniforms(src)
        if plain:
            emulated += 1
            errors += ["plain uniform `%s`: an emulation uniform of the GL translator, which Rive's web "
                       "runtime may query with no program bound (WebGL2 getUniform throws); "
                       "%s" % (u, "a vertex entry point reads @builtin(instance_index), use a vertex attribute"
                               if "first_instance" in u else "remove the WGSL feature that needs it")
                       for u in plain]
        shadows = SHADOW_SAMPLER.findall(src)
        if shadows:
            shadow += 1
            errors += ["shadow sampler `%s %s`: a WGSL sampler_comparison; Rive's web runtime queries the "
                       "program's samplers with no program bound and WebGL2's getUniform throws: read the "
                       "depth with textureLoad and compare in the shader" % t for t in shadows]
        if errors:
            failures += 1
            print("== shader %d (%s)" % (count - 1, stage))
            print("\n".join(errors[:5]))
    shutil.rmtree(tmp)
    if count == 0:
        print("ERROR: no GLSL ES 3.0 shaders found in %s" % path, file=sys.stderr)
        sys.exit(1)
    print("%d GLSL shaders, %d failing (%d with emulation uniforms, %d with shadow samplers)"
          % (count, failures, emulated, shadow))
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
