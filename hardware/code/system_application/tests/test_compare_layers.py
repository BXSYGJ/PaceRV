"""Unit tests for compare_layers.py (tasks.md T-M2-07, PC side).

The capture side is simulated offline: design.md 9.2 frames are built with
uart_frames.build_frame, reassembled and saved as layer_XX.npy exactly the
way uart_capture --frames --out-dir does.  No serial port, no PDS and no
TorchScript involvement -- the golden NPU references are injected as
synthetic tensors so the comparison statistics, the sampled (0x80) mask
and the shape checking are tested in isolation.
"""

from __future__ import annotations

import numpy as np
import pytest

import compare_layers as cl
import uart_frames as uf


def _save_layer(out_dir, layer_id, values):
    """Build a design.md 9.2 frame, reassemble it and save layer_XX.npy."""
    base = layer_id & 0x7F
    dtype = np.dtype(uf.LAYER_DTYPES[base]).newbyteorder('<')
    payload = np.asarray(values, dtype=dtype).tobytes()
    chunk = cl.FRAME_CHUNK_BYTES
    frames = []
    for seq, off in enumerate(range(0, max(len(payload), 1), chunk)):
        frames.extend(uf.parse_frames(
            uf.build_frame(layer_id, seq, payload[off:off + chunk])))
    arr = uf.reassemble(frames, layer_id)
    path = out_dir / f'layer_{layer_id:02x}.npy'
    np.save(path, arr)
    return path, arr


def _layer_size(layer_id):
    return int(np.prod(uf.LAYER_SHAPES[layer_id & 0x7F]))


def test_discover_layer_files_reads_hex_ids(tmp_path):
    _save_layer(tmp_path, 6, np.arange(8, dtype=np.int32))
    _save_layer(tmp_path, 0x81, np.arange(4, dtype=np.uint8))
    found = cl.discover_layer_files(tmp_path)
    assert sorted(found) == [0x06, 0x81]
    assert found[0x06].name == 'layer_06.npy'


def test_compare_dir_per_layer_stats(tmp_path):
    fc1 = np.arange(_layer_size(5), dtype=np.uint8)
    logits = np.array([5, -3, 7, 0, 1, -1, 2, 9], dtype=np.int32)
    _save_layer(tmp_path, 5, fc1)
    _save_layer(tmp_path, 6, logits)

    off = fc1.copy()
    off[0] = np.uint8((int(off[0]) + 1) & 0xFF)
    refs = {5: off, 6: logits.copy()}
    rows = cl.compare_dir(tmp_path, refs)

    assert [r['layer_id'] for r in rows] == [5, 6]
    fc1_row, logit_row = rows
    assert fc1_row['name'] == 'FC1'
    assert fc1_row['sampled'] is False
    assert fc1_row['coverage'] == 1.0
    assert fc1_row['within_1lsb'] == 1.0
    assert fc1_row['exact'] == pytest.approx(127.0 / 128.0)
    assert fc1_row['max_abs_delta'] == 1

    assert logit_row['name'] == 'FC2_LOGITS'
    assert logit_row['exact'] == 1.0
    assert logit_row['within_1lsb'] == 1.0
    assert logit_row['max_abs_delta'] == 0


def test_compare_dir_covers_every_requested_layer(tmp_path):
    for lid in (0, 1, 2, 3, 4, 5, 6, 7):
        _save_layer(tmp_path, lid, np.zeros(_layer_size(lid), np.int32))
    refs = {lid: np.zeros(uf.LAYER_SHAPES[lid], np.int64)
            for lid in (0, 1, 2, 3, 4, 5, 6, 7)}
    rows = cl.compare_dir(tmp_path, refs)
    assert [r['layer_id'] for r in rows] == [0, 1, 2, 3, 4, 5, 6, 7]
    assert all(r['error'] is None for r in rows)
    assert all(r['coverage'] == 1.0 for r in rows)
    assert all(r['exact'] == 1.0 for r in rows)


def test_stats_layer_is_skipped_not_failed(tmp_path):
    _save_layer(tmp_path, 8, np.arange(8, dtype=np.int32))
    rows = cl.compare_dir(tmp_path, {})
    assert len(rows) == 1
    assert rows[0]['skipped'] is True
    assert 'STATS' in rows[0]['error']
    assert cl.format_table(rows).count('skipped') == 1


def test_sampled_export_masks_unsampled_slots(tmp_path):
    layer_id = 0x80 | 1                    # sampled CONV1
    total = _layer_size(layer_id)
    step = 16
    count = (total + step - 1) // step
    values = np.arange(count, dtype=np.uint8) % 251

    path, saved = _save_layer(tmp_path, layer_id, values)
    assert saved.dtype == np.float64
    assert saved.shape == uf.LAYER_SHAPES[1]
    assert np.isnan(saved.reshape(-1)[1])

    # Reference that is WRONG everywhere except the exported slots: the
    # NaN mask must hide those positions, so exactness stays 1.0.
    ref = np.full(uf.LAYER_SHAPES[1], 255, dtype=np.uint8)
    ref.reshape(-1)[::step][:count] = values
    rows = cl.compare_dir(tmp_path, {1: ref})
    row = rows[0]
    assert row['sampled'] is True
    assert row['coverage'] == pytest.approx(count / total)
    assert row['exact'] == 1.0
    assert row['max_abs_delta'] == 0

    # And a real sampled mismatch is seen at 1/16 coverage.
    bad = ref.copy()
    bad.reshape(-1)[0] = np.uint8((int(values[0]) + 1) & 0xFF)
    rows = cl.compare_dir(tmp_path, {1: bad})
    assert rows[0]['exact'] == pytest.approx(1.0 - 1.0 / count)
    assert rows[0]['max_abs_delta'] == 1


def test_frames_from_sampled_array_rebuilds_mask(tmp_path):
    layer_id = 0x80 | 1
    total = _layer_size(layer_id)
    count = (total + 15) // 16
    values = np.zeros(count, dtype=np.uint8)
    _, saved = _save_layer(tmp_path, layer_id, values)
    frames = cl.frames_from_array(saved, layer_id)
    assert all(lid == layer_id for lid, _seq, _pay in frames)
    assert [seq for _lid, seq, _pay in frames] ==         list(range(len(frames)))                # sequential, no gaps
    assert sum(len(pay) for _lid, _seq, pay in frames) == count

    ref = np.full(uf.LAYER_SHAPES[1], 7, dtype=np.uint8)
    stats = cl.compare_array(saved, layer_id, ref)
    assert stats['coverage'] == pytest.approx(count / total)
    assert stats['max_abs_delta'] == 7          # sampled slot 0 differs


def test_shape_mismatch_is_reported(tmp_path):
    _save_layer(tmp_path, 6, np.arange(8, dtype=np.int32))
    refs = {6: np.zeros((8, 2), dtype=np.int32)}
    rows = cl.compare_dir(tmp_path, refs)
    assert rows[0]['error'] is not None
    assert 'shape mismatch' in rows[0]['error']
    with pytest.raises(ValueError, match='shape mismatch'):
        cl.compare_dir(tmp_path, refs, strict=True)


def test_float_reference_is_rejected(tmp_path):
    _save_layer(tmp_path, 7, np.zeros(_layer_size(7), np.uint8))
    rows = cl.compare_dir(tmp_path, {7: np.zeros(_layer_size(7), np.float64)})
    assert 'integer wire container' in rows[0]['error']


def test_missing_reference_is_reported(tmp_path):
    _save_layer(tmp_path, 5, np.arange(_layer_size(5), dtype=np.uint8))
    rows = cl.compare_dir(tmp_path, {})
    assert 'no golden reference' in rows[0]['error']


def test_truncated_capture_is_reported(tmp_path):
    # Only half of the FC2 int32 payload arrived -> reassembly cannot
    # reshape to the contract shape and the row records the failure.
    np.save(tmp_path / 'layer_06.npy', np.arange(4, dtype=np.int32))
    rows = cl.compare_dir(tmp_path, {6: np.zeros(8, np.int32)})
    assert rows[0]['error'] is not None


def test_no_layer_files_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        cl.compare_dir(tmp_path, {})


def _fake_npu():
    shapes = {lid: uf.LAYER_SHAPES[lid] for lid in range(7)}
    npu = {key: np.zeros(shapes[lid], np.uint8)
           for lid, (key, _dtype) in cl.LAYER_STAGE.items()
           if lid in shapes and lid != 0}
    npu['logits'] = np.arange(-4, 4, dtype=np.int32)
    npu['fc2'] = np.zeros(8, np.uint8)
    npu['percent'] = np.array([99, 0, 0, 1, 0, 0, 0, 0], np.int64)
    npu['probs_q16'] = np.array([65535, 0, 0, 256, 0, 0, 0, 0], np.int64)
    npu['top1'] = 0
    return npu


def test_references_from_npu_layer_map():
    feat = np.full(uf.LAYER_SHAPES[0], 49, dtype=np.uint8)
    refs = cl.references_from_npu(feat, _fake_npu(), 'percent')
    assert set(refs) == set(cl.LAYER_STAGE)
    assert refs[0].dtype == np.int16            # MEL_Q8_8 wire container
    assert refs[0].shape == uf.LAYER_SHAPES[0]
    assert int(refs[0].min()) == 49
    assert refs[1].dtype == np.uint8
    assert refs[6].dtype == np.int32
    assert refs[7].tolist() == [99, 0, 0, 1, 0, 0, 0, 0]


def test_probs_encodings():
    npu = _fake_npu()
    q08 = cl.encode_probs(npu, 'q0.8')
    assert q08.tolist() == [255, 0, 0, 1, 0, 0, 0, 0]
    with pytest.raises(ValueError):
        cl.encode_probs(npu, 'q0.16')


def test_reference_shape_drift_is_rejected():
    npu = _fake_npu()
    npu['conv1'] = np.zeros((48, 64, 256), np.uint8)
    feat = np.zeros(uf.LAYER_SHAPES[0], np.uint8)
    with pytest.raises(ValueError, match='reference shape'):
        cl.references_from_npu(feat, npu)


def test_load_feat_npy_rejects_float(tmp_path):
    path = tmp_path / 'bad_feat.npy'
    np.save(path, np.zeros(uf.LAYER_SHAPES[0], np.float32))
    with pytest.raises(ValueError, match='integer'):
        cl.load_feat_npy(path)


def test_load_feat_npy_accepts_archived_int8(tmp_path):
    path = tmp_path / 'feat.npy'
    np.save(path, np.zeros(uf.LAYER_SHAPES[0], np.int8))
    feat = cl.load_feat_npy(path)
    assert feat.dtype == np.uint8 and feat.shape == uf.LAYER_SHAPES[0]


def test_find_golden_feat_requires_unambiguous_stem(tmp_path):
    np.save(tmp_path / 'a_feat.npy', np.zeros(uf.LAYER_SHAPES[0], np.uint8))
    np.save(tmp_path / 'b_feat.npy', np.zeros(uf.LAYER_SHAPES[0], np.uint8))
    with pytest.raises(ValueError, match='several features'):
        cl.find_golden_feat(tmp_path)
    assert cl.find_golden_feat(tmp_path, 'b').name == 'b_feat.npy'
    with pytest.raises(FileNotFoundError):
        cl.find_golden_feat(tmp_path, 'missing')


def test_format_table_has_all_columns(tmp_path):
    _save_layer(tmp_path, 6, np.arange(8, dtype=np.int32))
    rows = cl.compare_dir(tmp_path, {6: np.arange(8, dtype=np.int64)},
                          layer_ids=[6])
    text = cl.format_table(rows, ['golden feat: x.npy'])
    assert 'coverage' in text and 'within1' in text and 'max|d|' in text
    assert '0x06' in text and 'FC2_LOGITS' in text
    assert '1 layer(s) compared' in text
    assert '[ref] golden feat: x.npy' in text


def test_main_reports_requested_but_missing_layer(tmp_path, capsys):
    _save_layer(tmp_path, 6, np.arange(8, dtype=np.int32))
    ref6 = tmp_path / 'ref6.npy'
    ref7 = tmp_path / 'ref7.npy'
    np.save(ref6, np.arange(8, dtype=np.int32))
    np.save(ref7, np.zeros(8, np.uint8))
    rc = cl.main([str(tmp_path), '--layer', '6,7',
                  '--ref', f'0x06={ref6}', '--ref', f'0x07={ref7}'])
    out = capsys.readouterr().out
    assert rc == 1
    assert 'requested but not captured: 0x07' in out
    assert '0x06' in out


def test_layer_filter_limits_rows(tmp_path):
    _save_layer(tmp_path, 5, np.arange(_layer_size(5), dtype=np.uint8))
    _save_layer(tmp_path, 6, np.arange(8, dtype=np.int32))
    refs = {5: np.arange(_layer_size(5), dtype=np.uint8),
            6: np.arange(8, dtype=np.int32)}
    rows = cl.compare_dir(tmp_path, refs, layer_ids=[0x86])
    assert [r['layer_id'] for r in rows] == [6]