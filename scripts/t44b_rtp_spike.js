/* T44b — RTP measurement harness for a Mattermost Calls SFU, run inside a browser page on the
 * server's own origin (so no CORS, and the real Chrome WebRTC engine negotiates the way the web
 * client does). Two peer connections of two sessions of the same fixture account join the same
 * call, each sends a synthetic oscillator tone, and the code reads the engine's own
 * `outbound-rtp` / `inbound-rtp` counters (the `getStats()` shape the acceptance criterion names).
 *
 *   const r = await t44bRtp({channel: 't44-calls', login: 'perfprobe', password: '…', seconds: 6});
 *
 * Everything it needs is here: a ~40-line MessagePack encoder (the plugin's `sdp` action only
 * accepts a MessagePack binary frame whose payload is zlib-compressed JSON — see docs/t44-calls-
 * media-path-2026-10-27.log and T44), the core `/api/v4/websocket` authentication challenge, and
 * the plugin's own action prefix.
 *
 * Nothing is written to the server except a call in `channel`, joined and left exactly as a client
 * would. The password is a value the caller supplies; this file contains no credential.
 */
window.t44bRtp = async function t44bRtp(opts) {
  const o = Object.assign({channel: 't44-calls', login: 'perfprobe', password: null,
                           seconds: 6, log: true}, opts || {});
  const PA = 'custom_com.mattermost.calls_';
  const lines = [];
  window.__t44bLines = lines;
  const L = (...a) => { const s = a.join(' '); lines.push(s); if (o.log) console.log('[t44b]', s); };

  // ---- MessagePack: only what the plugin's socket frames need (map/str/int/bin) -------------
  function mpEncode(v) {
    const parts = [];
    const push = (bytes) => { for (const b of bytes) parts.push(b); };
    const enc = (x) => {
      if (typeof x === 'number' && Number.isInteger(x) && x >= 0 && x < 128) { parts.push(x); return; }
      if (typeof x === 'number' && Number.isInteger(x) && x >= 0) {
        parts.push(0xce, (x >>> 24) & 255, (x >>> 16) & 255, (x >>> 8) & 255, x & 255); return;
      }
      if (typeof x === 'string') {
        const u = new TextEncoder().encode(x);
        if (u.length < 32) parts.push(0xa0 | u.length);
        else if (u.length < 256) parts.push(0xd9, u.length);
        else { parts.push(0xda, (u.length >> 8) & 255, u.length & 255); }
        push(u); return;
      }
      if (x instanceof Uint8Array) {
        if (x.length < 256) parts.push(0xc4, x.length);
        else { parts.push(0xc5, (x.length >> 8) & 255, x.length & 255); }
        push(x); return;
      }
      if (Array.isArray(x)) { parts.push(0x90 | x.length); x.forEach(enc); return; }
      if (x && typeof x === 'object') {
        const keys = Object.keys(x);
        if (keys.length < 16) parts.push(0x80 | keys.length);
        else parts.push(0xde, (keys.length >> 8) & 255, keys.length & 255);
        for (const k of keys) { enc(k); enc(x[k]); }
        return;
      }
      throw new Error('msgpack: unsupported ' + typeof x);
    };
    enc(v);
    return new Uint8Array(parts);
  }

  async function zlibCompress(bytes) {
    const cs = new CompressionStream('deflate');   // 'deflate' = zlib wrapper (RFC 1950)
    const stream = new Blob([bytes]).stream().pipeThrough(cs);
    return new Uint8Array(await new Response(stream).arrayBuffer());
  }

  // ---- REST ---------------------------------------------------------------------------------
  let token = null;
  async function rest(method, path, body) {
    const res = await fetch(path, {
      method,
      headers: Object.assign({'Content-Type': 'application/json'},
                             token ? {Authorization: 'Bearer ' + token} : {}),
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch (e) { /* non-JSON */ }
    if (method === 'POST' && path.endsWith('/users/login')) token = res.headers.get('Token') || token;
    return {status: res.status, json, text};
  }

  async function login() {
    const r = await rest('POST', '/api/v4/users/login', {login_id: o.login, password: o.password});
    if (r.status !== 200) throw new Error('login failed: ' + r.status + ' ' + r.text.slice(0, 200));
    L('login ok', r.json.username);
    const teams = await rest('GET', '/api/v4/users/me/teams');
    const team = teams.json[0];
    const ch = await rest('GET', `/api/v4/teams/${team.id}/channels/name/${o.channel}`);
    if (ch.status !== 200) throw new Error('channel lookup failed: ' + ch.status);
    L('channel', ch.json.name, ch.json.id);
    return {userId: r.json.id, channelId: ch.json.id};
  }

  // ---- one Calls session: a websocket + one RTCPeerConnection -------------------------------
  function openSession(name, channelId) {
    const s = {name, connID: null, ws: null, pc: null, msgs: [], errors: [], answerAt: null,
               joined: null, remoteCandidates: 0, unmuted: false, ctx: null};
    const ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host +
                             '/api/v4/websocket');
    s.ws = ws;
    s.ready = new Promise((resolve, reject) => {
      ws.onopen = () => {
        ws.send(JSON.stringify({seq: 1, action: 'authentication_challenge', data: {token}}));
        resolve();
      };
      ws.onerror = () => { s.errors.push('ws error'); reject(new Error(name + ': ws error')); };
      setTimeout(() => reject(new Error(name + ': ws did not open')), 15000);
    });
    s.opened = new Promise((resolve, reject) => {
      s._resolveJoined = resolve;
      setTimeout(() => reject(new Error(name + ': no connID')), 20000);
    });
    s.opened.catch(() => {});   // awaited later; keep the rejection from going unhandled
    ws.onmessage = async (ev) => {
      if (typeof ev.data !== 'string') return;           // binary frames are not used by the plugin
      let msg;
      try { msg = JSON.parse(ev.data); } catch (e) { return; }
      const event = msg.event || '';
      const data = msg.data || {};
      if (!event.startsWith(PA)) {
        if (event === 'hello') s.msgs.push('hello');
        return;
      }
      const local = event.slice(PA.length);
      s.msgs.push(local);
      if (local === 'signal') {
        let peek = null;
        try { peek = JSON.parse(data.data); } catch (e) { peek = null; }
        L(s.name, 'signal', peek && peek.type, 'connID', String(data.connID).slice(0, 6),
          'mine', String(s.connID).slice(0, 6));
      }
      if (local === 'join') {
        // Broadcast to the user, so it cannot say which of our two sockets it belongs to; the
        // socket's own connID is taken from its first answer below.
        s.ackConnID = data.connID || null;
        return;
      }
      if (local === 'signal') {
        // The plugin broadcasts signalling events to the *user*, so both of our sockets receive
        // both sessions' signals. The first answer we accept on a socket belongs to that socket's
        // session, and it carries the connID we filter on from then on.
        if (data.connID && s.connID && data.connID !== s.connID) return;   // the other session
        let inner = null;
        try { inner = JSON.parse(data.data); } catch (e) { return; }
        if (!inner || !s.pc) return;
        if (inner.type === 'answer') {
          if (!s.connID && data.connID) s.connID = data.connID;
          await s.pc.setRemoteDescription({type: 'answer', sdp: inner.sdp});
          s.answerAt = Date.now();
        } else if (inner.type === 'offer') {
          // The SFU renegotiates after the connection is up (that is how the media it forwards
          // toward this client is announced); a client that ignores it never receives audio.
          if (!s.connID && data.connID) s.connID = data.connID;
          s.serverOffers = (s.serverOffers || 0) + 1;
          await s.pc.setRemoteDescription({type: 'offer', sdp: inner.sdp});
          const ans = await s.pc.createAnswer();
          await s.pc.setLocalDescription(ans);
          const packed = await zlibCompress(new TextEncoder().encode(JSON.stringify(
            {type: 'answer', sdp: s.pc.localDescription.sdp})));
          s.ws.send(mpEncode({seq: 40 + s.serverOffers, action: PA + 'sdp', data: {data: packed}}));
          L(s.name, 'server offer answered,', s.pc.localDescription.sdp.length, 'sdp bytes;',
            'transceivers', s.pc.getTransceivers().length);
        } else if (inner.type === 'candidate' && inner.candidate) {
          try { await s.pc.addIceCandidate(inner.candidate); s.remoteCandidates++; } catch (e) { /* raced */ }
        }
        return;
      }
      if (local === 'call_state') {
        try { s.callState = JSON.parse(data.call); } catch (e) { /* ignore */ }
        const sess = (s.callState || {}).sessions || [];
        L(s.name, 'call_state sessions:',
          sess.map((x) => `${String(x.session_id).slice(0, 6)}(${x.user_id === me.userId ? 'me' : x.user_id},` +
                          `unmuted=${x.unmuted})`).join(' '));
        return;
      }
      if (local === 'error') { s.errors.push(String(data.data)); return; }
      s.msgs.push(local);
    };
    return s;
  }

  async function joinSession(s, channelId) {
    await s.ready;
    s.ws.send(JSON.stringify({seq: 2, action: PA + 'join', data: {channelID: channelId}}));
    // The join ack is broadcast to the user, so with two sockets of one account it does not say
    // which socket it belongs to. The socket's own connID arrives with its first answer instead.
    await new Promise(r => setTimeout(r, 1200));
    L(s.name, 'joined (connID learned on its first answer)');
  }

  function sendMsg(s, seq, action, data) {
    s.ws.send(JSON.stringify({seq, action: PA + action, data}));
  }

  async function offerFrom(s) {
    const pc = new RTCPeerConnection({iceServers: [], bundlePolicy: 'max-bundle'});
    s.pc = pc;
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    s.ctx = ctx;
    const osc = ctx.createOscillator();
    osc.frequency.value = s.freq;
    const gain = ctx.createGain();
    gain.gain.value = 0.15;
    const dest = ctx.createMediaStreamDestination();
    osc.connect(gain);
    gain.connect(dest);
    osc.start();
    // `resume()` can stay pending under an autoplay policy; never let it hold the run hostage.
    Promise.resolve(ctx.resume()).catch(() => {});
    await new Promise(r => setTimeout(r, 400));
    s.ctxState = ctx.state;
    s.track = dest.stream.getAudioTracks()[0];
    s.sender = pc.addTrack(s.track, dest.stream);
    // Without a sink that pulls the inbound stream the engine keeps the packets in its jitter
    // buffer and reports totalSamplesReceived = 0, so attach one: that is what makes the received
    // audio *decoded* rather than merely arrived.
    pc.ontrack = (e) => {
      s.remoteTrack = e.track;
      const el = document.createElement('audio');
      el.autoplay = true;
      el.muted = false;
      el.srcObject = e.streams[0] || new MediaStream([e.track]);
      el.style.display = 'none';
      document.body.appendChild(el);
      s.audioEl = el;
      el.play().catch((err) => L(s.name, 'audio play rejected', err && err.message));
      L(s.name, 'remote track received:', e.track.kind, '— attached to an <audio> sink');
    };
    L(s.name, 'audio context', ctx.state, 'track', s.track.readyState,
      'settings', JSON.stringify(s.track.getSettings()));

    const offer = await pc.createOffer({offerToReceiveAudio: true, offerToReceiveVideo: false});
    await pc.setLocalDescription(offer);
    await new Promise((resolve) => {
      if (pc.iceGatheringState === 'complete') return resolve();
      const done = () => { if (pc.iceGatheringState === 'complete') { pc.removeEventListener(
        'icegatheringstatechange', done); resolve(); } };
      pc.addEventListener('icegatheringstatechange', done);
      setTimeout(resolve, 3000);
    });
    const sdp = pc.localDescription.sdp;
    const packed = await zlibCompress(new TextEncoder().encode(JSON.stringify(
      {type: 'offer', sdp})));
    s.ws.send(mpEncode({seq: 3, action: PA + 'sdp', data: {data: packed}}));
    L(s.name, 'offer sent,', packed.length, 'compressed bytes, sdp', sdp.length,
      'candidates', (sdp.match(/^a=candidate:/gm) || []).length);
    await new Promise((resolve, reject) => {
      const t0 = Date.now();
      const tick = setInterval(() => {
        if (s.answerAt) { clearInterval(tick); resolve(); }
        else if (Date.now() - t0 > 10000) { clearInterval(tick); reject(new Error(s.name + ': no answer')); }
      }, 50);
    });
    L(s.name, 'answer applied');
  }

  async function waitConnected(s, timeoutMs) {
    const pc = s.pc;
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      if (['connected', 'completed'].includes(pc.connectionState) ||
          ['connected', 'completed'].includes(pc.iceConnectionState)) return true;
      await new Promise(r => setTimeout(r, 200));
    }
    return false;
  }

  async function snap(pc) {
    const stats = await pc.getStats();
    const codecs = {};
    stats.forEach((r) => { if (r.type === 'codec') codecs[r.id] = r.mimeType; });
    const out = {outbound: [], inbound: [], pairs: [], candidates: []};
    stats.forEach((r) => {
      const kind = r.kind || r.mediaType;
      if (r.type === 'outbound-rtp' && kind === 'audio') {
        out.outbound.push({ssrc: r.ssrc, packetsSent: r.packetsSent, bytesSent: r.bytesSent,
                           codec: codecs[r.codecId] || r.codecId, clock: r.timestamp});
      }
      if (r.type === 'inbound-rtp' && kind === 'audio') {
        out.inbound.push({ssrc: r.ssrc, packetsReceived: r.packetsReceived,
                          packetsLost: r.packetsLost,
                          bytesReceived: r.bytesReceived,
                          totalSamplesReceived: r.totalSamplesReceived,
                          concealedSamples: r.concealedSamples, totalAudioEnergy: r.totalAudioEnergy,
                          audioLevel: r.audioLevel, jitter: r.jitter,
                          codec: codecs[r.codecId] || r.codecId, clock: r.timestamp});
      }
      if (r.type === 'candidate-pair' && (r.nominated || r.state === 'succeeded')) {
        out.pairs.push({state: r.state, nominated: !!r.nominated,
                        bytesSent: r.bytesSent, bytesReceived: r.bytesReceived,
                        local: r.localCandidateId, remote: r.remoteCandidateId});
      }
      if (r.type === 'remote-candidate' || r.type === 'local-candidate') {
        out.candidates.push({id: r.id, type: r.type, address: r.address, port: r.port,
                             protocol: r.protocol, candidateType: r.candidateType});
      }
    });
    return out;
  }

  // ---- run -----------------------------------------------------------------------------------
  const t0 = performance.now();
  const me = await login();
  const a = openSession('peer-A', me.channelId);
  const b = openSession('peer-B', me.channelId);
  a.freq = 440; b.freq = 660;
  await joinSession(a, me.channelId);
  await joinSession(b, me.channelId);
  await offerFrom(a);
  await offerFrom(b);

  const connected = {A: await waitConnected(a, 25000), B: await waitConnected(b, 25000)};
  L('connected', JSON.stringify(connected));

  // Unmute both sessions (the fixture's default session state is muted) and let the SFU know.
  for (const s of [a, b]) { sendMsg(s, 10, 'unmute', {channelID: me.channelId}); s.unmuted = true; }
  await new Promise(r => setTimeout(r, 1500));

  const s1 = {A: await snap(a.pc), B: await snap(b.pc)};
  await new Promise(r => setTimeout(r, o.seconds * 1000));
  const s2 = {A: await snap(a.pc), B: await snap(b.pc)};

  const delta = (x, y, field) => (y === undefined || x === undefined) ? null : y - x;
  const summary = {};
  for (const k of ['A', 'B']) {
    const o1 = s1[k].outbound[0] || {}, o2 = s2[k].outbound[0] || {};
    const i1 = s1[k].inbound[0] || {}, i2 = s2[k].inbound[0] || {};
    summary[k] = {
      outbound_packets: delta(o1.packetsSent, o2.packetsSent),
      outbound_bytes: delta(o1.bytesSent, o2.bytesSent),
      inbound_packets: delta(i1.packetsReceived, i2.packetsReceived),
      inbound_bytes: delta(i1.bytesReceived, i2.bytesReceived),
      inbound_samples: delta(i1.totalSamplesReceived, i2.totalSamplesReceived),
      inbound_energy: delta(i1.totalAudioEnergy, i2.totalAudioEnergy),
      inbound_concealed: delta(i1.concealedSamples, i2.concealedSamples),
      inbound_lost: delta(i1.packetsLost, i2.packetsLost),
      inbound_jitter: i2.jitter,
      inbound_codec: i2.codec,
      outbound_codec: o2.codec,
      pair_bytes: s2[k].pairs[0] ? {sent: s2[k].pairs[0].bytesSent,
                                   received: s2[k].pairs[0].bytesReceived,
                                   state: s2[k].pairs[0].state} : null,
      inbound_audio_level: i2.audioLevel,
      pair: s2[k].pairs[0] || null,
      remote_candidate: (() => {
        const pair = s2[k].pairs[0];
        if (!pair) return null;
        const c = s2[k].candidates.find(x => x.id === pair.remote);
        return c ? `${c.address}:${c.port}/${c.protocol} ${c.candidateType}` : pair.remote;
      })(),
/*
 * The counters above are the same fields `getStats()` reports for `outbound-rtp` /
 * `inbound-rtp`, sampled twice `seconds` apart; the delta is what the call actually carried.
 */
    };
  }

  // leave, exactly as a client does
  for (const s of [a, b]) {
    try { sendMsg(s, 99, 'leave', {channelID: me.channelId}); } catch (e) { /* already gone */ }
  }
  await new Promise(r => setTimeout(r, 500));
  for (const s of [a, b]) {
    try { s.track && s.track.stop(); } catch (e) {}
    try { s.ctx && s.ctx.close(); } catch (e) {}
    try { s.pc && s.pc.close(); } catch (e) {}
    try { s.ws && s.ws.close(); } catch (e) {}
  }

  const result = {
    channel: o.channel, user_id: me.userId, elapsed_ms: Math.round(performance.now() - t0),
    connected, sessions: {A: {connID: a.connID, ctxState: a.ctxState, remoteCandidates: a.remoteCandidates,
                              errors: a.errors, callStateSessions: (a.callState || {}).sessions?.length},
                          B: {connID: b.connID, ctxState: b.ctxState, remoteCandidates: b.remoteCandidates,
                              errors: b.errors, callStateSessions: (b.callState || {}).sessions?.length}},
    sample1: s1, sample2: s2, delta: summary, log: lines,
  };
  window.__t44b = result;
  return result;
};
'harness-loaded';
