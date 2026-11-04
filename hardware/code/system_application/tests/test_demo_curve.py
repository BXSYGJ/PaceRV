import sys
from pathlib import Path
import pytest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from set_demo_curve import compile_curve

def test_interpolation_and_final_endpoint():
    words=compile_curve([{'time':0,'pct':[100,0,0,0,0,0,0,0]},
                         {'time':0.2,'pct':[0,0,0,0,0,0,0,100]}])
    assert words == [100, 50+(50<<56), 100<<56]

@pytest.mark.parametrize('points', [[], [{'time':1,'pct':[0]*8}],
    [{'time':0,'pct':[101]*8}], [{'time':0,'pct':[0]*7}],
    [{'time':0,'pct':[0]*8},{'time':410,'pct':[0]*8}]])
def test_bad_curve_rejected(points):
    with pytest.raises(ValueError): compile_curve(points)


def test_supplied_montage_timeline():
    import json
    from set_demo_curve import timeline_points
    root = Path(__file__).resolve().parents[1]
    data = json.loads((root/'data/demo/confidence_timeline.json').read_text(encoding='utf-8'))
    points = timeline_points(data)
    words = compile_curve(points)
    assert len(data['windows']) == 114
    assert len(words) == 581
    assert words[0] & 255 == 100
    assert words[-1] >> 56 == 100
    assert {max(range(8), key=lambda i: (word >> (8*i)) & 255) for word in words} == set(range(8))
    rom = [int(s,16) for s in (root/'src/ui/demo_confidence.hex').read_text().splitlines()]
    assert rom[:len(words)] == words
    assert rom[len(words):] == [words[-1]]*(4096-len(words))
    labels = json.loads((root/'src/ui/demo_dashboard_assets.json').read_text(encoding='utf-8'))
    assert labels['classes'][:8] == data['classes_zh']
    assert 'female' not in data['classes']
