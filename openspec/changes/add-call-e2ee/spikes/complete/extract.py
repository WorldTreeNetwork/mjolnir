"""Reassemble actual transport-decrypted QUIC STREAM bytes; retain private outputs only.
Tap payloads select exact bytes inside capture streams, not substitute media bytes.
"""
import xml.etree.ElementTree as E,json,base64,sys,struct,subprocess,pathlib
root=pathlib.Path(sys.argv[1]);mode=sys.argv[2]
streams={};packets=0;segments=0
for _,packet in E.iterparse(sys.stdin.buffer if '--stdin' in sys.argv else root/(mode+'.pdml'),events=['end']):
 if packet.tag!='packet':continue
 packets+=1
 def field(node,name):
  return next((x for x in node.iter('field') if x.get('name')==name),None)
 src=field(packet,'udp.srcport');src=src.get('show') if src is not None else '?'
 for proto in packet.findall("proto[@name='quic']"):
  conn=field(proto,'quic.connection.number');conn=conn.get('show') if conn is not None else '?'
  for frame in proto.findall("field[@name='quic.frame']"):
   data=field(frame,'quic.stream_data');sid=field(frame,'quic.stream.stream_id');offset=field(frame,'quic.stream.offset')
   if data is None or sid is None or not data.get("value"):continue
   key=(conn,src,sid.get('show'));off=int(offset.get('show')) if offset is not None else 0
   buf=bytes.fromhex(data.get('value'));streams.setdefault(key,{})[off]=buf;segments+=1
 packet.clear()
joined=[];holes=0
for key,parts in streams.items():
 buf=bytearray();cursor=0
 for off,data in sorted(parts.items()):
  if off>cursor:
   # Keep contiguous fragments separate; never bridge holes with invented bytes.
   if buf:joined.append(bytes(buf))
   buf=bytearray();cursor=off;holes+=1
  end=off+len(data)
  if end>cursor:buf.extend(data[max(0,cursor-off):]);cursor=end
 if buf:joined.append(bytes(buf))
assert joined and sum(map(len,joined))>1000,'no decrypted stream data'
tap=json.loads((root/(mode+'-tap.json')).read_text());tracks=tap['data'][0]['tracks'];recovered={};matches={}
for name,frames in tracks.items():
 found=[];seen=set()
 for f in frames:
  needle=base64.b64decode(f['payload']);ident=(f['group'],f['index'])
  if ident in seen:continue
  seen.add(ident)
  for stream in joined:
   at=stream.find(needle)
   if at>=0:
    found.append((int(f['group']),f['index'],stream[at:at+len(needle)]));break
 recovered[name]=sorted(found);matches[name]=len(found)
assert matches.get('video',0)>15,'capture does not recover actual video payloads'
# Every reconstructed frame below is sliced from transport-decrypted capture bytes.
video=[]
for group,index,payload in recovered['video']:
 n=1<<(payload[0]>>6)
 raw=payload[n:] if mode=='plaintext' else payload
 if not raw:continue
 if mode=='plaintext' and not video and raw[0]&1:continue
 video.append(raw)
ivf=struct.pack('<4sHH4sHHIIII',b'DKIF',0,32,b'VP80',320,180,30,1,len(video),0)
for i,raw in enumerate(video):ivf+=struct.pack('<IQ',len(raw),i)+raw
(root/(mode+'.ivf')).write_bytes(ivf)
r=subprocess.run(['ffmpeg','-v','error','-i',str(root/(mode+'.ivf')),'-f','framemd5','-'],capture_output=True)
frames=[x for x in r.stdout.splitlines() if x and not x.startswith(b'#')]
(root/(mode+'-decode.log')).write_bytes(r.stderr)
MARKERS=['catalog.json','video','audio','alice/call','call','E2EE-TEST-DISPLAY-ALICE-57']
markers={m:any(m.encode() in s for s in joined) for m in MARKERS}
markerCounts={m:sum(s.count(m.encode()) for s in joined) for m in MARKERS}
# Codec-level scan of ALL reassembled bytes, independent of the reference payloads:
# a VP8 keyframe start code followed by a plausible picture size (16..4096 each way).
import re as _re
def _vp8(s):
 n=0
 for m in _re.finditer(_re.escape(b'\x9d\x01\x2a'),s):
  w,h=struct.unpack('<HH',s[m.end():m.end()+4].ljust(4,b'\0'));w&=0x3fff;h&=0x3fff
  n+=16<=w<=4096 and 16<=h<=4096
 return n
vp8Keyframes320=sum(_vp8(s) for s in joined)
vp8StartCodes=sum(s.count(b'\x9d\x01\x2a') for s in joined)
# Opus packets reconstructed independently from captured audio payloads.
def ogg_page(payload,seq,granule,bos=False):
 laces=bytes([255]*(len(payload)//255)+[len(payload)%255])
 page=bytearray(b'OggS'+bytes([0,2 if bos else 0])+struct.pack('<QII',granule,57,seq)+b'\0'*4+bytes([len(laces)])+laces+payload)
 crc=0
 for byte in page:
  crc^=byte<<24
  for _ in range(8):crc=((crc<<1)^0x04c11db7 if crc&0x80000000 else crc<<1)&0xffffffff
 page[22:26]=struct.pack('<I',crc);return page
opushead=b'OpusHead'+bytes([1,2])+struct.pack('<HIhB',312,48000,0,0)
ogg=ogg_page(opushead,0,0,True)+ogg_page(b'OpusTags'+struct.pack('<II',0,0),1,0)
for i,(_,_,payload) in enumerate(recovered.get('audio',[])):
 raw=payload[1<<(payload[0]>>6):] if mode=='plaintext' else payload
 ogg+=ogg_page(raw,i+2,(i+1)*960)
(root/(mode+'.ogg')).write_bytes(ogg)
ar=subprocess.run(['ffmpeg','-v','error','-i',str(root/(mode+'.ogg')),'-f','f32le','-'],capture_output=True)
(root/(mode+'-audio-decode.log')).write_bytes(ar.stderr)
import array,math
samples=array.array('f');samples.frombytes(ar.stdout)
rms=math.sqrt(sum(x*x for x in samples)/max(1,len(samples)))
# An Opus decoder turns arbitrary bytes into some audio, so RMS alone proves nothing for ciphertext.
# Goertzel at 440 Hz on channel 0: ~1 for the injected tone, ~0 for noise.
def tone(ch,rate=48000,f=440.0,n=4800):
 c=2*math.cos(2*math.pi*f/rate);ratios=[]
 for b in range(0,len(ch)-n,n):
  s1=s2=0.0;e=0.0
  for x in ch[b:b+n]:s0=x+c*s1-s2;s2=s1;s1=s0;e+=x*x
  p=s1*s1+s2*s2-c*s1*s2
  if e>1e-9:ratios.append(p/(e*n/2))
 return sum(ratios)/len(ratios) if ratios else 0.0
tone440=tone(samples[0::2])
key=bytes([17])*32
key_leaks={kind:any(value in buf for buf in joined) for kind,value in {'raw':key,'hex':key.hex().encode(),'base64url':base64.urlsafe_b64encode(key).rstrip(b'=')}.items()}
result={'mode':mode,'packetsWithStreamData':packets,'streamSegments':segments,'reassembledFragments':len(joined),'bytes':sum(map(len,joined)),'holes':holes,'capturedPayloadMatches':matches,'markers':markers,'decoder':'ffmpeg VP8 IVF -> framemd5','decoderExit':r.returncode,'decodedFrames':len(frames),'uniqueDecodedFrames':len(set(x.split(b',')[-1] for x in frames)),'decoderErrorBytes':len(r.stderr),'audioDecoderExit':ar.returncode,'audioDecodedSamples':len(samples),'audioRms':rms,'audioDecoderErrorBytes':len(ar.stderr),'contentKeyLeaks':key_leaks,'markerCounts':markerCounts,'vp8KeyframeHeaders':vp8Keyframes320,'vp8StartCodes3byte':vp8StartCodes,'audioTone440Ratio':tone440}
print(json.dumps(result));(root/(mode+'-results.json')).write_text(json.dumps(result))
if mode=='plaintext':assert len(frames)>15 and result['uniqueDecodedFrames']>10 and len(samples)>10000 and rms>0.01 and vp8Keyframes320>0 and tone440>0.5
elif mode=='encrypted':assert len(frames)==0 and not any(markers.values()) and vp8Keyframes320==0 and tone440<0.05 and not any(key_leaks.values()),'PASSIVE CAPTURE FAILED'
else:assert len(frames)==0 and vp8Keyframes320==0 and tone440<0.05 and not any(key_leaks.values()),'TOKEN-ONLY CAPTURE DECODED MEDIA'
