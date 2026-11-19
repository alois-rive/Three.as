"""Where the sample files the tools/make_*_samples.py generators write live.

The repository holds two Rive projects (see README.md): the gallery's
examples read some samples (packages/gallery/examples/<example>/), the
engine's test suites read others (packages/threeas/tests/fixtures/), and a
few are read by both, so they have a copy in each. A generator writes a
file to its first place with `path(name)` and then calls `copy(name)` to
refresh the other copies:

    write_hdr(sample_paths.path("studio_rgbe.hdr"), ...)
    sample_paths.copy("studio_rgbe.hdr")
"""
import os
import shutil

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
GALLERY = os.path.join(ROOT, "packages", "gallery", "examples")
FIXTURES = os.path.join(ROOT, "packages", "threeas", "tests", "fixtures")


def _example(name):
    return os.path.join(GALLERY, name)


# file -> the folders holding it, the first being where it is generated.
PLACES = {
    # make_cube_faces.py
    **{f"studio_{face}.png": [_example("environments")] for face in ("px", "nx", "py", "ny", "pz", "nz")},
    # make_hdr_samples.py
    "studio_rgbe.hdr": [_example("shared"), FIXTURES],
    "studio_exr.exr": [_example("environments"), FIXTURES],
    # make_ktx2_samples.py
    "checker_bc1.ktx2.zlib": [_example("textures"), FIXTURES],
    "checker_astc.ktx2.zlib": [_example("textures"), FIXTURES],
    # make_lut_samples.py
    "warm_grade.cube": [_example("effects")],
    "warm_grade_3dl.3dl": [_example("effects")],
    # make_mesh_samples.py
    "pyramid_binary.stl": [FIXTURES],
    "pyramid_ascii.stl": [FIXTURES],
    "cube_ascii.ply": [FIXTURES],
    "quad_binary.ply": [FIXTURES],
    # make_fbx_samples.py (fbx_nurbs.fbx is not generated)
    "fbx_scene.fbx": [_example("models"), FIXTURES],
    "fbx_v7500.fbx": [FIXTURES],
    "fbx_ascii.fbx": [FIXTURES],
    # make_gltf_samples.py
    "features.glb": [_example("models"), FIXTURES],
    "features_embedded.gltf": [FIXTURES],
    # make_sample_glb.py
    "sample.glb": [_example("model")],
}


def path(name):
    """Where the generator writes `name` (its first place)."""
    return os.path.join(PLACES[name][0], name)


def copy(name):
    """Copies `name` from its first place to the others."""
    for folder in PLACES[name][1:]:
        shutil.copyfile(path(name), os.path.join(folder, name))


def rel(name):
    """`name`'s places, relative to the repository root, for messages."""
    return " and ".join(os.path.relpath(os.path.join(f, name), ROOT) for f in PLACES[name])
