# System Design

## Design Decisions

### Why RTMP over SRT for ingest?

I initially designed the system with SRT (Secure Reliable Transport) for lower latency contribution. However, CloudFormation's MediaLive resource doesn't fully support the `SRT_LISTENER` input type via API. RTMP push is universally supported by all encoders (OBS, VOS, MediaKind, Mwedge) and works reliably with MediaLive's CloudFormation integration. For a production deployment at scale, SRT would be preferred and configured via the console or CLI directly.

### Why Lambda over Step Functions + MediaConvert for clipping?

The initial design used Step Functions to orchestrate a MediaPackage harvest job followed by MediaConvert transcoding. This approach had several drawbacks:
- Harvest jobs take 30+ seconds to complete
- MediaConvert adds additional processing time
- More moving parts = more failure points
- Higher cost per clip

The Lambda approach uses MediaPackage v2's time-shifted playback feature to fetch segments directly from the live buffer. This is:
- Faster (clips available in ~15 seconds)
- Cheaper (Lambda execution vs MediaConvert per-minute pricing)
- Simpler (single function, no state machine)

### Why MediaPackage v2 over v1?

MediaPackage v2 offers:
- Native CloudFormation support for all resources including endpoint policies
- Time-shifted playback (startover window) without additional configuration
- Better integration with CloudFront OAC
- Simpler channel group model

### Why SMART_CROP over manual crop coordinates?

MediaLive's `SMART_CROP` scaling behaviour delegates crop decisions to Elemental Inference. The AI analyses each frame and determines the optimal crop region based on:
- Subject detection (players, ball)
- Motion tracking
- Scene composition

A fixed centre crop would miss action happening on the wings. A manual crop requires human operators. SMART_CROP is fully autonomous.

## Data Flow

### Live Stream Path (latency: ~10-15 seconds end-to-end)

```
Encoder → RTMP → MediaLive (encode + AI crop) → HLS → MediaPackage v2 → CloudFront → Viewer
                                                  └→ RTMP → TikTok/YouTube/Instagram/Facebook
```

### Highlight Clip Path (latency: ~15-20 seconds from detection to S3)

```
Elemental Inference detects event
    → EventBridge fires (Clip Metadata Generated)
    → Lambda invoked
    → Waits 10s for segments to be available
    → Fetches time-shifted manifest from MediaPackage v2
    → Downloads relevant segments
    → Builds VOD HLS manifest
    → Uploads to S3
    → SNS notification sent
```

## Encoder Settings

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Resolution | 1080x1920 | Full HD vertical — standard for TikTok/Reels |
| Frame rate | 30 fps | Social platform standard |
| Codec | H.264 High Profile | Universal playback compatibility |
| Bitrate | 6-8 Mbps CBR | High quality for sport content with fast motion |
| GOP | 48-60 frames (2s) | Balance between compression and seek accuracy |
| PAR | 9:16 | Correct aspect ratio signalling for players |
| Audio | AAC-LC, 192 kbps, 48 kHz stereo | Broadcast quality |

## Cost Model

| Component | Billing | Typical cost (1hr stream) |
|-----------|---------|--------------------------|
| MediaLive | Per running hour | ~$0.87 |
| Elemental Inference | Per hour analysed | ~$0.20 |
| MediaPackage v2 | Per GB originated | ~$0.14 |
| Lambda | Per invocation + duration | ~$0.01 per clip |
| S3 | Per GB stored | negligible |
| CloudFront | Per GB transferred | ~$0.01 |
| **Total** | | **~$1.25/hr** |

The channel is only billed when running. All other components are pay-per-use with no idle cost.

## Failure Handling

- MediaLive: `InputLossAction: EMIT_OUTPUT` — continues encoding even if input drops temporarily
- Lambda: 120s timeout, retries on transient failures
- HLS CDN: `ConnectionRetryInterval: 1`, `NumRetries: 10` — automatic reconnection to MediaPackage
- S3: Versioning enabled on clips bucket — no data loss from overwrites
- CloudWatch alarm on input loss (configurable)

## Security

- Input security group restricts RTMP access by source IP
- MediaPackage endpoint policy controls who can read the stream
- S3 buckets have public access blocked — served only via CloudFront OAC
- IAM roles follow least-privilege principle
- Social media stream keys stored as `NoEcho` parameters (never logged)
