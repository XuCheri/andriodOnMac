# Mac → Android protocol v1

Both USB (ADB reverse TCP) and LAN use the same TLS 1.2+ server. The receiver pins SHA-256 of the server certificate DER. No trust-all fallback. QR / authorized USB bootstrap JSON: `{ "v":1, "host":"...", "port":12345, "fingerprint":"lowercase hex", "pairToken":"random single-use token" }`. Android launch intent string extra is `connection`; USB uses `aom:` followed by URL-safe unpadded Base64 of this UTF-8 JSON so the ADB shell cannot reinterpret its quotes. QR contains the raw JSON. Package `chat.xucheri.androidonmac.receiver`, activity `.MainActivity`.

Each TLS connection uses framed messages: 4-byte unsigned big-endian body length (10...8388608), then 1-byte kind (1=JSON, 2=H264 Annex B video access unit, 3=raw AAC access unit), 8-byte unsigned big-endian PTS in microseconds, 1-byte flags (bit0=keyframe), then payload. JSON is UTF-8. Reject unknown kinds, oversized and truncated frames. Control JSON is at most 65536 bytes. All integers in JSON are safe within signed 53-bit range.

Receiver opens a control connection and sends `{"type":"hello","protocolVersion":1,"channel":"control","deviceID":"persistent UUID","deviceName":"...","pairToken":"..."}` on first pairing, or `authToken` instead of pairToken for saved pairing. Mac asks the user to approve the new device. Server responds `{"type":"paired","authToken":"random secret","sessionID":"UUID"}`. Tokens must never be logged. A new media TLS connection then sends hello with the same protocolVersion/deviceID, `channel:"media"`, authToken and sessionID. Authenticated saved devices also receive `paired` with a fresh sessionID. Only one receiver/session is accepted. The Mac UI must have an explicitly started/waiting session; authentication never starts idle sharing.

Mac sends on media channel:
- `{"type":"videoConfig","codec":"h264","width":1920,"height":1080,"csd0":"base64 Annex B SPS","csd1":"base64 Annex B PPS"}` before frames and on reconfiguration.
- `{"type":"audioConfig","codec":"aac","sampleRate":48000,"channels":2,"csd":"base64 AudioSpecificConfig"}` if audio is enabled. AAC payload has no ADTS header.
- video/audio framed access units; keyframes include Annex B SPS/PPS as well.

Control channel accepts:
- `{"type":"ping"}` / response `{"type":"pong"}` every 2 seconds; 8-second silence disconnects.
- `{"type":"firstFrame"}` only after Android renders first decoded frame.
- `{"type":"stats","frames":123,"queueDepth":0}` at most once a second.
- `{"type":"requestKeyFrame"}` following decoder reset / loss.
- `{"type":"input","action":"move|down|up|click|doubleClick|rightClick","x":0.5,"y":0.5}` normalized to displayed video content, excluding bars.
- `{"type":"input","action":"scroll","dx":0.0,"dy":-24.0}` pixel deltas.
- `{"type":"input","action":"text","text":"中文"}` committed text, max 4096 UTF-8 bytes.
- `{"type":"input","action":"key","key":"enter|backspace|delete|escape|tab|left|right|up|down|home|end|copy|paste|cut|selectAll|undo|redo"}`. `delete` means forward delete; `backspace` deletes before the cursor.
- `{"type":"stop"}` stops this session. Mac sends `{"type":"stopped"}` or `{"type":"error","message":"safe user message"}`. Receiver never reconnects after explicit stop.

Reconnect delays are 1/2/4 seconds, at most three attempts. A successful first rendered frame ends recovery. Pair approval remains required for unknown devices. Reconnection never changes saved certificate/device identity or downgrades TLS. On disconnect both sides discard partial frames, reset codecs and release input; use a new sessionID and keyframe. Android backgrounding/locking sends stop and closes; rotation only relayouts the Surface. Hardware low-latency decoder is enabled only when advertised by codec capabilities.

Runtime statistics are diagnostic only; do not record frames, text, pairing tokens, or clipboard content. This protocol is local-only, without cloud rendezvous or relay.
