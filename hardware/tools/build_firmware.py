"""Rebuild CPU CoreMark firmware using the included frozen compiler argv."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cpu', choices=['performance_155250', 'efficiency_145125'])
    parser.add_argument('--role', choices=['V0', 'V1'], default='V0')
    parser.add_argument('--prefix', required=True, help='Compiler prefix, e.g. C:/Toolchain/bin/riscv-none-embed-')
    args = parser.parse_args()
    base = ROOT / 'code/bare_cpu' / args.cpu
    recipe = json.loads((base / 'firmware/recipe.json').read_text(encoding='utf-8-sig'))
    out = ROOT / 'build/firmware' / args.cpu / args.role
    out.mkdir(parents=True, exist_ok=True)
    def exe(name):
        p = Path(args.prefix + name)
        if p.is_file():
            return str(p)
        if Path(str(p) + '.exe').is_file():
            return str(p) + '.exe'
        raise FileNotFoundError(p)
    argv = [s.replace('{RELEASE}', base.as_posix()).replace('{OUTPUT}', out.as_posix())
            for s in recipe['roles'][args.role]['argv']]
    subprocess.run([exe('gcc')] + argv, cwd=out, check=True)
    binary = out / 'firmware.bin'
    subprocess.run([exe('objcopy'), '-O', 'binary', str(out / 'firmware.elf'), str(binary)], check=True)
    data = binary.read_bytes()
    if len(data) > 65536:
        raise ValueError('Firmware exceeds 64 KiB backing memory')
    data += bytes(65536 - len(data))
    text = ''.join(f'{int.from_bytes(data[i:i+4], "little"):08x}\n' for i in range(0, len(data), 4))
    hexfile = out / 'firmware.hex'
    hexfile.write_text(text, encoding='ascii')
    print('Output:', hexfile)
    print('Reference SHA256:', recipe['roles'][args.role]['reference_hex_sha256'])
    print('Rebuilt SHA256:  ', hashlib.sha256(hexfile.read_bytes()).hexdigest())
    print('Use the same compiler release to reproduce the exact binary. Frozen inputs remain unchanged.')


if __name__ == '__main__':
    main()
