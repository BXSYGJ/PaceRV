"""Offline only: encode/verify weight frames and prepare silent-input reference.

No serial, downloader, USB enumeration, sockets or processes are accessed.
The wire blob is a codec artifact; real upload must still wait for each ACK.
"""
import binascii
import hashlib
import json
from pathlib import Path
import numpy as np
import golden_pipeline as golden
import weight_upload as upload

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/rv_board_smoke_offline'
OUT.mkdir(parents=True,exist_ok=True)
image_path=ROOT/'scripts/outputs/weights_image.bin'
image=image_path.read_bytes()
frames=list(upload.iter_frames(image))
encoded=[]
for seq,payload in frames:
    frame=upload.build_frame(seq,payload)
    assert frame[:2]==b'\xaa\x55'
    assert int.from_bytes(frame[2:4],'little')==seq
    assert int.from_bytes(frame[4:6],'little')==len(payload)
    assert int.from_bytes(frame[-2:],'little')==binascii.crc_hqx(frame[2:-2],0xffff)
    encoded.append(frame)
assert b''.join(payload for seq,payload in frames[:-1])==image
wire=b''.join(encoded)
(OUT/'weights_wire_frames.bin').write_bytes(wire)
acc=[0,0,0,0]
for beat in range(0,len(image),32):
    data=image[beat:beat+32].ljust(32,b'\0')
    words=[int.from_bytes(data[i:i+4],'little') for i in range(0,32,4)]
    for lane in range(4):acc[lane]=(acc[lane]+words[lane]+words[lane+4])&0xffffffff
digest=acc[0]^acc[1]^acc[2]^acc[3]
feature=np.full((64,258),49,dtype=np.uint8)
result=golden.npu_forward(feature,golden.load_layer_contract(),golden.load_mel_tables()['exp_lut'])
probs=[int(x) for x in result['probs_q16']]
pcts=[int(round(x*100/65536)) for x in probs]
(OUT/'silence_feature_frame_major.hex').write_text(''.join(f'{int(v):02x}\n' for v in feature.T.reshape(-1)),encoding='ascii')
manifest={'offline_only':True,'board_result':'NOT_RUN','image':{'path':str(image_path.relative_to(ROOT)),
 'bytes':len(image),'sha256':hashlib.sha256(image).hexdigest()},'data_frames':len(frames)-1,
 'total_frames':len(frames),'last_payload_bytes':len(frames[-2][1]),'wire_bytes':len(wire),
 'wire_sha256':hashlib.sha256(wire).hexdigest(),'crc_check':'all frames independently checked using binascii.crc_hqx init FFFF',
 'expected_wok':f'WOK {digest:08X}','minimum_tx_seconds_115200_8n1':round(len(wire)*10/115200,3),
 'minimum_ack_seconds_115200_8n1':round((len(frames)-1)*10/115200,3),
 'silence_model':{'not_board_evidence':True,'feature_shape':[64,258],'feature_value':49,'top1':int(np.argmax(probs)),
 'fc2_logits':[int(x) for x in result['fc2']],'probs_q16':probs,'probability_pct':pcts,
 'last_class':7,'last_probability_pct':pcts[7]},
 'production_rom_sha256':hashlib.sha256((ROOT/'src/cpu/prog.hex').read_bytes()).hexdigest(),
 'assets':str(OUT),'raw_blob_is_not_a_valid_unpaced_upload':True}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='ascii')
(ROOT/'reports/rv_board_smoke_offline_20261101.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='ascii')
print(json.dumps(manifest,indent=2))
