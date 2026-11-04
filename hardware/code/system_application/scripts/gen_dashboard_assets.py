"""Freeze the dashboard's Chinese glyphs and tile map for synchronous RTL ROMs."""
from pathlib import Path
import hashlib
import json
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'src/ui'
CLASSES = ['单簧管', '失真电吉他', '女声', '长笛', '钢琴', '次中音萨克斯', '小号', '小提琴', '等待识别']
ENGLISH = ['clarinet', 'distorted electric guitar', 'female singer', 'flute', 'piano', 'tenor saxophone', 'trumpet', 'violin']


def generate(demo=None):
    global OUT, CLASSES
    if demo is not None:
        CLASSES = demo["classes_zh"] + ["等待播放"]
    assert demo is not None or json.loads((ROOT / 'scripts/outputs/layer_contract.json').read_text(encoding='utf-8'))['classes']['names'] == ENGLISH
    font_path = Path('C:/Windows/Fonts/msyh.ttc')
    ascii_path = Path('C:/Windows/Fonts/consola.ttf')
    chinese = ImageFont.truetype(str(font_path), 27)
    ascii_font = ImageFont.truetype(str(ascii_path), 26)
    glyphs = [[0] * 32]
    lookup = {}
    tiles = [0] * 4096
    texts = []

    def chunks(char):
        if char not in lookup:
            width = 16 if ord(char) < 128 else 32
            im = Image.new('1', (width, 32))
            d = ImageDraw.Draw(im)
            font = ascii_font if width == 16 else chinese
            box = d.textbbox((0, 0), char, font=font)
            d.text(((width - (box[2]-box[0]))//2-box[0], (32-(box[3]-box[1]))//2-box[1]), char, font=font, fill=1)
            ids = []
            for offset in range(0, width, 16):
                ids.append(len(glyphs))
                glyphs.append([sum(int(im.getpixel((offset+x, y)) != 0) << (15-x) for x in range(16)) for y in range(32)])
            lookup[char] = ids
        return lookup[char]

    def put(x, y, text, color=1, mode=0):
        assert x % 16 == 0 and y % 32 == 0
        texts.append(dict(x=x, y=y, text=text, mode=mode))
        col = x//16
        for c in text:
            for token in chunks(c):
                addr = y//32*120+col
                assert tiles[addr] == 0, (text, addr)
                tiles[addr] = color << 12 | mode << 8 | token
                col += 1

    put(64, 64, 'INSTREC / 乐器识别', 3)
    put(64, 112-16, '观察声音  ·  查看频谱  ·  了解识别结果', 2)
    put(1632, 64, '曲线演示' if demo else '仿真演示', 4, 0 if demo else 6)
    put(96, 192, '01 输入波形')
    put(96, 224, '声音振幅随时间变化', 2)
    put(80, 288, '+1', 2)
    put(96, 352, '0', 2)
    put(80, 416, '-1', 2)
    put(128, 448, '较早', 2)
    put(576, 448, '时间 / 3 秒', 2)
    put(1056, 448, '较近', 2)
    put(448, 352, '等待音频窗口', 2, 4)
    put(96, 576, '02 Mel 频谱')
    put(96, 608, '颜色表示频带能量，横向为时间', 2)
    put(80, 672, '高', 2)
    put(80, 896, '低', 2)
    put(128, 928, '较早', 2)
    put(1056, 928, '较近', 2)
    put(448, 768, '等待频谱数据', 2, 5)
    put(128, 960, 'Mel 频带 / 64', 2)
    put(768, 960, '能量', 2)
    put(864, 960, '弱', 2)
    put(1120, 960, '强', 2)
    put(1248, 192, '03 预设置信度回放' if demo else '03 最近识别结果')
    put(1280, 336-16, '置信度', 2)
    put(1280, 384, '类别置信度', 2)
    if not demo:
        put(1280, 960, '百分比表示模型置信度', 2)
    for i, label in enumerate(CLASSES[:8]):
        put(1280, 448+64*i, label, 1)
    # Dynamic large class: each 16x32 source tile occupies 32x64 pixels.
    for y in range(8, 10):
        for x in range(80, 112):
            tiles[y*120+x] = 0x3100 | ((x-80)//2)
    for slot in range(9):
        x, y = (1488, 320) if slot == 8 else (1728, 448+64*slot)
        for digit in range(4):
            tiles[y//32*120+x//16+digit] = 0x1200 | (slot<<4) | digit
    for c in '0123456789-% ':
        chunks(c)
    ascii_ids = [lookup.get(chr(i), [0])[0] for i in range(128)]
    class_ids = []
    for label in CLASSES:
        ids = [n for c in label for n in chunks(c)]
        class_ids.extend(ids + [0]*(16-len(ids)))
    assert len(glyphs) <= 256, len(glyphs)
    glyphs.extend([[0]*32 for _ in range(256-len(glyphs))])
    class_ids.extend([0]*(256-len(class_ids)))

    def write(name, values, width):
        (OUT / (("demo_" if demo else "") + name)).write_text(''.join(f'{v:0{width}x}\n' for v in values), encoding='ascii')
    write('dashboard_font.hex', [v for g in glyphs for v in g], 4)
    write('dashboard_tiles.hex', tiles, 4)
    write('dashboard_ascii.hex', ascii_ids, 2)
    write('dashboard_classes.hex', class_ids, 2)
    metadata = dict(classes=CLASSES, texts=texts, glyph_chunks=len(lookup), font_sha256=hashlib.sha256(font_path.read_bytes()).hexdigest(), ascii_sha256=hashlib.sha256(ascii_path.read_bytes()).hexdigest())
    (OUT / ('demo_dashboard_assets.json' if demo else 'dashboard_assets.json')).write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print('Dashboard ROM assets generated:', len(lookup), 'characters')


if __name__ == '__main__':
    generate()
