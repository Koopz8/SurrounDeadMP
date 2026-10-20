"""Build the Nexus download: dist/SurrounDeadCoop-<version>.zip

Run from the repo root:  python tools/make_release.py

The zip extracts straight into SurrounDead/Binaries/Win64 and contains:
  dwmapi.dll + ue4ss/UE4SS.dll   UE4SS loader (from tools/UE4SS-dev.zip, no .pdb)
  ue4ss/UE4SS-settings.ini       our settings (UE 5.3, console off)
  ue4ss/Mods/...                 UE4SS's stock mods + shared libs (UEHelpers)
  ue4ss/Mods/SurrounDeadCoop/    the mod (Scripts/main.lua + enabled.txt)
  SurrounDeadCoop-README.txt
"""
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
MAIN = os.path.join(ROOT, "mods", "SDMPDiag", "Scripts", "main.lua")
UE4SS_ZIP = os.path.join(TOOLS, "UE4SS-dev.zip")
SETTINGS = os.path.join(TOOLS, "release", "UE4SS-settings.ini")
README = os.path.join(TOOLS, "release", "README.txt")
MOD = "SurrounDeadCoop"

src = open(MAIN, encoding="utf-8").read()
m = re.search(r'local SDMP_VERSION = "([^"]+)"', src)
if not m:
    sys.exit("no SDMP_VERSION in main.lua")
version = m.group(1)

out_dir = os.path.join(ROOT, "dist")
os.makedirs(out_dir, exist_ok=True)
out = os.path.join(out_dir, "%s-%s.zip" % (MOD, version))

skip_ext = (".pdb",)
keep_top = ("ue4ss/UE4SS.dll", "ue4ss/LICENSE")

with zipfile.ZipFile(UE4SS_ZIP) as uz, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for info in uz.infolist():
        name = info.filename
        if name.endswith("/") or name.endswith(skip_ext):
            continue
        if name == "dwmapi.dll" or name in keep_top or name.startswith("ue4ss/Mods/"):
            z.writestr(name, uz.read(name))
    z.write(SETTINGS, "ue4ss/UE4SS-settings.ini")
    z.writestr("ue4ss/Mods/%s/Scripts/main.lua" % MOD, src)
    z.writestr("ue4ss/Mods/%s/enabled.txt" % MOD, "")
    z.write(README, "%s-README.txt" % MOD)

print("wrote", out, "(%d KB)" % (os.path.getsize(out) // 1024))
