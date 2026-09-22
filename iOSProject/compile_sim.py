import os
import subprocess
import glob

OPENBST_ROOT = "/Users/devinprater/openbst"
BUILD_DIR = "/Users/devinprater/openbst_ios/build_sim_clean"
SDK_PATH = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).decode().strip()

os.makedirs(BUILD_DIR, exist_ok=True)

c_files = glob.glob(f"{OPENBST_ROOT}/src/**/*.c", recursive=True)
objects = []

for src_file in c_files:
    rel_path = os.path.relpath(src_file, OPENBST_ROOT)
    obj_name = rel_path.replace(os.sep, "_").replace(".c", ".o")
    obj_file = os.path.join(BUILD_DIR, obj_name)
    
    cmd = [
        "clang", "-target", "arm64-apple-ios-simulator",
        "-isysroot", SDK_PATH,
        "-O2", "-g", "-Wall", "-Wextra", "-std=gnu11",
        f"-I{OPENBST_ROOT}/include", "-fPIC",
        "-c", src_file, "-o", obj_file
    ]
    subprocess.run(cmd, check=True)
    objects.append(obj_file)

# Archive into libbst_sim.a
lib_path = "/Users/devinprater/openbst_ios/libbst_sim.a"
subprocess.run(["ar", "rcs", lib_path] + objects, check=True)
print(f"Successfully created {lib_path}")
