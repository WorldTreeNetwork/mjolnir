// WHIP/WHEP test page for the webrtc-edge spike. Query: ?edge=<http base>&room=<room>; token in the
// fragment (#t=<jwt>) so it never reaches the static server's log. Drivers call window.* below.
const q = new URLSearchParams(location.search);
const f = new URLSearchParams(location.hash.slice(1));
history.replaceState(null, '', location.pathname + location.search);
const edge = q.get('edge'), room = q.get('room');
let token = f.get('t');
window.setToken = t => { token = t; };
window.log = [];
const log = (...a) => { const s = a.join(' '); window.log.push(s); console.log(s); };

function prefer(tr, kind, mime, dir) {
  if (!mime) return;
  const caps = (dir === 'send' ? RTCRtpSender : RTCRtpReceiver).getCapabilities(kind);
  const pick = caps.codecs.filter(c => c.mimeType.toLowerCase() === ('video/' + mime).toLowerCase());
  if (!pick.length) throw Error('browser has no ' + mime);
  const rest = caps.codecs.filter(c => /rtx|red|ulpfec|flexfec/i.test(c.mimeType));
  try { tr.setCodecPreferences([...pick, ...rest]); }
  catch (e) { tr.setCodecPreferences(RTCRtpReceiver.getCapabilities(kind).codecs.filter(c => c.mimeType.toLowerCase() === ('video/' + mime).toLowerCase())); }
}

async function negotiate(kind, b, pc, tok = token) {
  await pc.setLocalDescription(await pc.createOffer());
  await new Promise(r => {
    if (pc.iceGatheringState === 'complete') return r();
    pc.addEventListener('icegatheringstatechange', () => pc.iceGatheringState === 'complete' && r());
    setTimeout(r, 2000);
  });
  const headers = { 'content-type': 'application/sdp' };
  if (tok) headers.authorization = 'Bearer ' + tok;
  if (q.get('root')) headers['x-mjolnir-root'] = q.get('root');
  const t0 = performance.now();
  const res = await fetch(`${edge}/${kind}/${room}/${b}`, { method: 'POST', headers, body: window.stripCandidates ? pc.localDescription.sdp.replace(/a=candidate:[^\r\n]*\r\n/g, '') : pc.localDescription.sdp });
  const text = await res.text();
  if (res.status !== 201) { const e = Error(`${kind} ${b}: HTTP ${res.status} ${text}`); e.status = res.status; throw e; }
  await pc.setRemoteDescription({ type: 'answer', sdp: text });
  return { location: res.headers.get('location'), answer: text, postMs: Math.round(performance.now() - t0) };
}

function connected(pc, ms = 10000) {
  return new Promise((res, rej) => {
    const t0 = performance.now();
    const check = () => {
      if (pc.connectionState === 'connected') res(Math.round(performance.now() - t0));
      if (pc.connectionState === 'failed') rej(Error('pc failed'));
    };
    pc.addEventListener('connectionstatechange', check); check();
    setTimeout(() => rej(Error('pc not connected: ' + pc.connectionState)), ms);
  });
}

window.pcs = {};
window.ended = {};
function watchEnd(name, pc) {
  const t0 = performance.now();
  pc.addEventListener('connectionstatechange', () => {
    if (['disconnected', 'failed', 'closed'].includes(pc.connectionState) && !window.ended[name]) {
      window.ended[name] = { state: pc.connectionState, afterMs: Math.round(performance.now() - t0), at: Date.now() };
      log('ended', name, pc.connectionState);
    }
  });
}

async function trackRms(track) {
  const ctx = new AudioContext(); await ctx.resume();
  const src = ctx.createMediaStreamSource(new MediaStream([track]));
  const an = ctx.createAnalyser(); an.fftSize = 8192; src.connect(an);
  await new Promise(r => setTimeout(r, 400));
  const td = new Float32Array(an.fftSize); an.getFloatTimeDomainData(td);
  const rms = Math.sqrt(td.reduce((s, x) => s + x * x, 0) / td.length);
  const fr = new Float32Array(an.frequencyBinCount); an.getFloatFrequencyData(fr);
  let best = 0; for (let i = 1; i < fr.length; i++) if (fr[i] > fr[best]) best = i;
  const hz = Math.round(best * ctx.sampleRate / an.fftSize);
  await ctx.close();
  return { rms: +rms.toFixed(4), hz, label: track.label, settings: track.getSettings() };
}

window.publish = async (b, vcodec, tok) => {
  const stream = await navigator.mediaDevices.getUserMedia({ video: { width: 1280, height: 720, frameRate: 30 }, audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
  const localAudio = await trackRms(stream.getAudioTracks()[0]);
  const pc = new RTCPeerConnection();
  const vt = pc.addTransceiver(stream.getVideoTracks()[0], { direction: 'sendonly' });
  pc.addTransceiver(stream.getAudioTracks()[0], { direction: 'sendonly' });
  prefer(vt, 'video', vcodec, 'send');
  const r = await negotiate('whip', b, pc, tok);
  const connectMs = await connected(pc);
  window.pcs['pub:' + b] = pc; watchEnd('pub:' + b, pc);
  log('published', b, 'connect', connectMs);
  return { location: r.location, postMs: r.postMs, connectMs, answerCodecs: codecsIn(r.answer), localAudio };
};

// Three simulcast layers on one video line (rids f/h/q), as a conferencing client would send.
window.publishSimulcast = async (b, tok) => {
  const stream = await navigator.mediaDevices.getUserMedia({ video: { width: 1280, height: 720, frameRate: 30 }, audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
  const pc = new RTCPeerConnection();
  pc.addTransceiver(stream.getVideoTracks()[0], { direction: 'sendonly', sendEncodings: [{ rid: 'q', scaleResolutionDownBy: 4 }, { rid: 'h', scaleResolutionDownBy: 2 }, { rid: 'f' }] });
  pc.addTransceiver(stream.getAudioTracks()[0], { direction: 'sendonly' });
  const r = await negotiate('whip', b, pc, tok);
  const connectMs = await connected(pc);
  window.pcs['pub:' + b] = pc; watchEnd('pub:' + b, pc);
  return { location: r.location, connectMs, answerSimulcast: (r.answer.match(/a=(simulcast|rid):[^\r\n]*/g) || []) };
};

window.play = async (b, vcodec, tok) => {
  const pc = new RTCPeerConnection();
  const vt = pc.addTransceiver('video', { direction: 'recvonly' });
  pc.addTransceiver('audio', { direction: 'recvonly' });
  prefer(vt, 'video', vcodec, 'recv');
  const ms = new MediaStream();
  pc.ontrack = e => ms.addTrack(e.track);
  const r = await negotiate('whep', b, pc, tok);
  const connectMs = await connected(pc);
  const v = document.createElement('video'); v.autoplay = true; v.muted = true; v.playsInline = true; v.width = 320;
  v.srcObject = ms; document.body.append(v); v.play().catch(() => {});
  const a = document.createElement('audio'); a.autoplay = true; a.srcObject = ms; a.volume = 0.01; document.body.append(a); a.play().catch(() => {});
  window.pcs['play:' + b] = Object.assign(pc, { video: v, stream: ms });
  watchEnd('play:' + b, pc);
  log('playing', b, 'connect', connectMs);
  return { location: r.location, postMs: r.postMs, connectMs, answerCodecs: codecsIn(r.answer) };
};

function codecsIn(sdp) {
  return [...sdp.matchAll(/a=rtpmap:\d+ ([^/\r\n]+)/g)].map(m => m[1]).filter(c => !/rtx|red|ulpfec/i.test(c));
}

window.stats = async name => {
  const pc = window.pcs[name]; const s = await pc.getStats(); const codecs = {}; const out = {};
  s.forEach(x => { if (x.type === 'codec') codecs[x.id] = x.mimeType + (x.sdpFmtpLine ? ' ' + x.sdpFmtpLine : ''); });
  out.outbound = [];
  s.forEach(x => {
    if (x.type === 'outbound-rtp' && x.kind === 'video') out.outbound.push({ rid: x.rid, frameWidth: x.frameWidth, framesEncoded: x.framesEncoded, bytesSent: x.bytesSent, active: x.active, qualityLimitationReason: x.qualityLimitationReason });
    if (x.type === 'inbound-rtp') out[x.kind + 'In'] = {
      codec: codecs[x.codecId], framesDecoded: x.framesDecoded, keyFramesDecoded: x.keyFramesDecoded, frameWidth: x.frameWidth, frameHeight: x.frameHeight,
      packetsReceived: x.packetsReceived, packetsLost: x.packetsLost, nackCount: x.nackCount, pliCount: x.pliCount, firCount: x.firCount,
      totalAudioEnergy: x.totalAudioEnergy, audioLevel: x.audioLevel, bytesReceived: x.bytesReceived, freezeCount: x.freezeCount };
    if (x.type === 'outbound-rtp') out[x.kind + 'Out'] = {
      codec: codecs[x.codecId], framesEncoded: x.framesEncoded, keyFramesEncoded: x.keyFramesEncoded, frameWidth: x.frameWidth, frameHeight: x.frameHeight,
      packetsSent: x.packetsSent, bytesSent: x.bytesSent, nackCount: x.nackCount, pliCount: x.pliCount, firCount: x.firCount,
      qualityLimitationReason: x.qualityLimitationReason, encoderImplementation: x.encoderImplementation, rid: x.rid };
  });
  out.state = pc.connectionState;
  return out;
};

// Content: average colour of the left and right halves of the decoded picture, and the audio peak.
window.content = async name => {
  const pc = window.pcs[name]; const v = pc.video;
  const c = document.createElement('canvas'); c.width = 64; c.height = 36; const g = c.getContext('2d');
  g.drawImage(v, 0, 0, 64, 36); const d = g.getImageData(0, 0, 64, 36).data;
  const avg = (x0, x1) => { let r = 0, gg = 0, b = 0, n = 0; for (let y = 4; y < 32; y++) for (let x = x0; x < x1; x++) { const i = (y * 64 + x) * 4; r += d[i]; gg += d[i + 1]; b += d[i + 2]; n++; } return [r / n, gg / n, b / n].map(Math.round); };
  const out = { left: avg(4, 28), right: avg(36, 60), videoWidth: v.videoWidth, videoHeight: v.videoHeight };
  const track = pc.stream.getAudioTracks()[0];
  if (track) {
    const ctx = new AudioContext(); await ctx.resume();
    const src = ctx.createMediaStreamSource(new MediaStream([track])); const an = ctx.createAnalyser(); an.fftSize = 8192; src.connect(an);
    await new Promise(r => setTimeout(r, 600));
    const fr = new Float32Array(an.frequencyBinCount); an.getFloatFrequencyData(fr);
    let best = 0; for (let i = 1; i < fr.length; i++) if (fr[i] > fr[best]) best = i;
    const td = new Float32Array(an.fftSize); an.getFloatTimeDomainData(td);
    out.audioPeakHz = Math.round(best * ctx.sampleRate / an.fftSize); out.audioPeakDb = Math.round(fr[best]);
    out.audioRms = +Math.sqrt(td.reduce((s, x) => s + x * x, 0) / td.length).toFixed(4);
    ctx.close();
  }
  return out;
};

window.roster = async () => {
  const res = await fetch(`${edge}/roster/${room}`, { headers: { authorization: 'Bearer ' + token } });
  return res.json();
};

window.stop = async name => {
  const pc = window.pcs[name]; const loc = pc.location; pc.close();
};
window.ready = true;
