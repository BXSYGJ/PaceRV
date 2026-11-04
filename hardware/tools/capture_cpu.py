"""Capture or audit a complete CPU UART frame against its frozen reference."""
from pathlib import Path
import argparse
import json
import re
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def audit(data, base, role):
    text = data.decode('ascii').replace('\r\n', '\n')
    start = text.find('ZGTC COREMARK READY')
    end = text.find('ZGTC COREMARK FINISHED\n', start)
    if start < 0 or end < 0:
        raise ValueError('Incomplete CoreMark UART frame')
    frame = text[start:end + len('ZGTC COREMARK FINISHED\n')]
    reference = (base / 'firmware' / role / 'uart.log').read_text(encoding='ascii')
    if frame != reference.replace('\r\n', '\n'):
        raise ValueError('UART output differs from the selected frozen reference')
    match = re.search(r'cycles_hex=([0-9a-fA-F]{16}) retired_hex=([0-9a-fA-F]{16}) clock_hz=(\d+)', frame)
    if not match:
        raise ValueError('Missing 64-bit measurement counters')
    cycles, retired = (int(match[i], 16) for i in (1, 2))
    hz = int(match[3])
    recipe = json.loads((base / 'firmware/recipe.json').read_text(encoding='utf-8-sig'))
    if hz != recipe['clock_hz'] or cycles / hz < 10:
        raise ValueError('Clock or minimum benchmark duration check failed')
    return {'status': 'PASS', 'cpu': base.name, 'role': role, 'board': '100Pro+',
            'configured_clock_hz': hz, 'cycles': cycles, 'retired_instructions': retired,
            'iterations': recipe['iterations'], 'seconds': cycles / hz,
            'coremark': recipe['iterations'] * hz / cycles,
            'coremark_per_mhz': recipe['iterations'] * 1e6 / cycles}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cpu', choices=['performance_155250', 'efficiency_145125'])
    parser.add_argument('--role', choices=['V0', 'V1'], default='V0')
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--port')
    source.add_argument('--capture-file', type=Path, help='Audit existing bytes; does not access a board')
    parser.add_argument('--output', type=Path, required=True, help='New capture directory')
    parser.add_argument('--timeout', type=float, default=120)
    args = parser.parse_args()
    if args.timeout <= 0:
        raise ValueError('Timeout must be positive')
    args.output.mkdir(parents=True, exist_ok=False)
    base = ROOT / 'code/bare_cpu' / args.cpu
    if args.capture_file:
        data = args.capture_file.read_bytes()
    else:
        import serial
        data = bytearray()
        deadline = time.monotonic() + args.timeout
        sent = False
        with serial.Serial(port=None, baudrate=9600, timeout=0.1, rtscts=False, dsrdtr=False) as port:
            port.port = args.port
            port.dtr = False
            port.rts = False
            port.open()
            print('UART open. Reset the FPGA now; the tool sends G after READY.', flush=True)
            while time.monotonic() < deadline:
                data.extend(port.read(max(1, port.in_waiting)))
                if not sent and b'ZGTC COREMARK READY' in data:
                    port.write(b'G')
                    port.flush()
                    sent = True
                if b'ZGTC COREMARK FINISHED\n' in data or b'ZGTC COREMARK FINISHED\r\n' in data:
                    break
        data = bytes(data)
    (args.output / 'uart.bin').write_bytes(data)
    result = audit(data, base, args.role)
    result['input_kind'] = 'existing_capture_audit' if args.capture_file else 'serial_capture'
    (args.output / 'measurement.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, UnicodeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
