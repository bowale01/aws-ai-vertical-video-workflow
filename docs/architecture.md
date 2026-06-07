# System Architecture

## High-Level Flow

```
Live Source (16:9) → RTMP Ingest → MediaLive + Elemental Inference (AI crop)
    → 9:16 Vertical Output → MediaPackage v2 (HLS) + RTMP (Social Platforms)
    → CloudFront CDN → Viewers (phone/browser)

Parallel: AI detects highlights → EventBridge → Lambda → Time-shifted fetch → S3 clips → SNS notify
```

## Architecture Diagram

```
  Encoder (OBS/VOS)              AWS Cloud (us-east-1)
┌──────────────┐    ┌──────────────────────────────────────────────────────────────┐
│              │    │                                                              │
│ 16:9 source  │    │      ┌─────────────────────────────────────────┐            │
│ (live sport) │    │      │   AWS Elemental Inference               │            │
│              │    │      │  ┌──────────┐ ┌──────────┐ ┌─────────┐ │            │
│ 1920x1080    │    │      │  │ Analysis │▶│Reasoning │▶│Smart    │ │            │
│ 30fps        │    │      │  │          │ │          │ │Crop     │ │            │
│ H.264        │    │      │  └──────────┘ └──────────┘ └─────────┘ │            │
│              │    │      │                    │ Highlight detect    │            │
│              │    │      │                    └──────────────────┐ │            │
└──────┬───────┘    │      └──────────────────────────────────────┐│ │            │
       │            │                   crop coords               ││ │            │
       │ RTMP Push  │  ┌───────────┐◀──────────────────────────────┘│ │            │
       │ :1935      │  │  AWS      │                                │ │            │
       └────────────┼─▶│ Elemental │                                │ │            │
                    │  │ MediaLive │                                │ │            │
                    │  │ (SMART_CROP)                               │ │            │
                    │  └─────┬─────┘                                │ │            │
                    │        │ 1080x1920 (9:16)                     │ │            │
                    │        │                                      │ │            │
                    │   ┌────┴──────────────────────────────────┐   │ │            │
                    │   │         Output destinations           │   │ │            │
                    │   ├───────────────────────────────────────┤   │ │            │
                    │   │ HLS → MediaPackage v2                 │   │ │            │
                    │   │ RTMP → TikTok LIVE                    │   │ │            │
                    │   │ RTMP → YouTube Shorts                 │   │ │            │
                    │   │ RTMP → Instagram Reels                │   │ │            │
                    │   │ RTMP → Facebook LIVE                  │   │ │            │
                    │   └────┬──────────────────────────────────┘   │ │            │
                    │        │                                      │ │            │
                    │        ▼ HLS                  EventBridge   ◀─┘ │            │
                    │  ┌───────────┐                     │            │            │
                    │  │MediaPackage│                    ▼            │            │
                    │  │ v2 (JITP) │           ┌──────────────────┐  │            │
                    │  └─────┬─────┘           │  Lambda          │  │            │
                    │        │                 │  (time-shifted   │  │            │
                    │        │                 │   clip fetch)    │  │            │
                    │        │                 └────────┬─────────┘  │            │
                    │        │                          │            │            │
                    │        │                 ┌────────▼─────────┐  │            │
                    │        │                 │    Amazon S3     │  │            │
                    │        │                 │  (highlight clips)│  │            │
                    │        │                 └────────┬─────────┘  │            │
                    │        ▼                          ▼            │            │
                    │  ┌──────────────────────────────────────────┐  │            │
                    │  │       Amazon CloudFront (CDN)            │  │            │
                    │  │  Live: MediaPackage  │  VOD clips: S3    │  │            │
                    │  └──────────────────────────────────────────┘  │            │
                    │                     │                           │            │
                    └─────────────────────┼───────────────────────────┘            │
                                          │                                        │
              ┌───────────────────────────┼──────────────────────────────┐         │
              ▼                           ▼                              ▼         │
        📱 TikTok                  📱 Phone/Browser             📺 YouTube/IG/FB
       (RTMP LIVE)               (HLS via CloudFront)           (RTMP LIVE)
```

## Component Breakdown

### Ingest Layer
- RTMP push input on port 1935
- Input security group with IP whitelisting
- Supports any RTMP-capable encoder (OBS, VOS, MediaKind, Mwedge)

### AI Processing Layer
- AWS Elemental Inference feed associated with the MediaLive channel
- Smart crop analyses every frame for region of interest
- Dynamically adjusts crop window to follow action (ball, players, key moments)
- Outputs crop coordinates back to MediaLive in real time
- Also detects highlight events (goals, tackles, celebrations) and fires EventBridge events

### Encoding Layer
- MediaLive channel with SMART_CROP scaling behaviour
- Output: 1080x1920 (9:16 portrait), H.264 High Profile, 6-8 Mbps
- Single pipeline (cost-optimised for demo/dev)
- PAR 9:16 for correct display on all players

### Packaging Layer
- MediaPackage v2 with just-in-time packaging (JITP)
- HLS output with 6-second segments
- 900-second startover window (enables time-shifted playback for clipping)
- Origin endpoint policy for CloudFront access

### Delivery Layer
- CloudFront CDN with MediaPackage v2 origin (live) and S3 origin (clips)
- RTMP push to TikTok, YouTube, Instagram, Facebook (conditional — only active when stream keys provided)
- HTTPS delivery globally

### Highlight Clipping Layer
- EventBridge rule listens for `Clip Metadata Generated` events from Elemental Inference
- Lambda function triggered automatically
- Uses MediaPackage v2 time-shifted playback to fetch the exact highlight window
- Downloads segments, builds VOD HLS manifest, saves to S3
- SNS notification sent with clip metadata

## Infrastructure as Code

The entire system is defined in a single CloudFormation template (`medialive-vertical.yaml`). One command deploys all resources, one command tears them down. No manual console configuration required.

## Scalability

- MediaLive supports multiple simultaneous channels
- MediaPackage v2 scales automatically with viewer count
- CloudFront provides global edge delivery
- Lambda scales to handle concurrent highlight events
- The architecture is stateless — no persistent servers to manage
