# OBS Studio Setup Guide for AWS Elemental Vertical Video

Quick reference for configuring OBS Studio to stream 9:16 vertical video to AWS MediaLive via RTMP.

---

## Prerequisites

- OBS Studio installed ([download here](https://obsproject.com))
- AWS CloudFormation stack deployed (`vertical-video-demo`)
- MediaLive channel started (RUNNING state)

---

## Step 1: Get your RTMP endpoint

> ⚠️ **Important:** The RTMP IP address changes every time you redeploy the stack. Always run this command after a fresh deploy.

```powershell
aws medialive list-inputs `
  --region us-east-1 `
  --query "Inputs[?Name=='vertical-video-demo-rtmp-input'].[Id,Destinations[0].Url]" `
  --output table
```

**Copy the URL** — it looks like: `rtmp://x.x.x.x:1935/vertical-video-demo`

---

## Step 2: Configure OBS

### Stream Settings

**Settings → Stream:**

| Setting | Value |
|---------|-------|
| Service | **Custom** |
| Server | `rtmp://YOUR_IP:1935/vertical-video-demo` (from step above) |
| Stream Key | `stream` |

Click **Apply** → **OK**

### Video Settings

**Settings → Video:**

| Setting | Value |
|---------|-------|
| Base (Canvas) Resolution | 1920x1080 |
| Output (Scaled) Resolution | **1080x1920** |
| Downscale Filter | Lanczos |
| Common FPS Values | **30** |

### Output Settings

**Settings → Output → Streaming:**

| Setting | Value |
|---------|-------|
| Output Mode | Advanced |
| Encoder | x264 |
| Rate Control | **CBR** |
| Bitrate | **6000** Kbps |
| Keyframe Interval | **2** seconds |
| CPU Usage Preset | veryfast |
| Profile | **high** |
| Tune | (none) |

### Audio Settings

**Settings → Audio:**

| Setting | Value |
|---------|-------|
| Sample Rate | 48 kHz |
| Channels | Stereo |

### Stream Settings

**Settings → Stream:**

| Setting | Value |
|---------|-------|
| Service | **Custom** |
| Server | `srt://YOUR_ENDPOINT:9000` (paste from Step 1) |
| Stream Key | (leave blank) |

Click **Apply** → **OK**

---

## Step 3: Add a video source

Choose one:

### Option A: Webcam
1. Sources → **+** → **Video Capture Device**
2. Select your webcam
3. Click OK

### Option B: Screen capture
1. Sources → **+** → **Display Capture**
2. Select your display
3. Click OK

### Option C: Video file (best for testing)
1. Sources → **+** → **Media Source**
2. Browse to a video file (e.g., a football match)
3. Check **Loop**
4. Click OK

---

## Step 4: Start streaming

1. **Start MediaLive channel first:**
   ```bash
   CHANNEL_ID=$(aws cloudformation describe-stacks \
     --stack-name vertical-video-demo \
     --region us-east-1 \
     --query "Stacks[0].Outputs[?OutputKey=='MediaLiveChannelId'].OutputValue" \
     --output text)
   
   aws medialive start-channel --channel-id $CHANNEL_ID --region us-east-1
   ```

2. Wait 30-60 seconds for channel to reach RUNNING state

3. In OBS, click **Start Streaming**

4. Check the status bar at the bottom — it should show green and "Live"

---

## Step 5: View the output

Get the playback URL:

```bash
# Get CloudFront domain
CF_DOMAIN=$(aws cloudformation describe-stacks \
  --stack-name vertical-video-demo \
  --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDomain'].OutputValue" \
  --output text)

# Get MediaPackage manifest path
MP_PATH=$(aws mediapackagev2 get-origin-endpoint \
  --channel-group-name vertical-video-demo-channel-group \
  --channel-name vertical-video-demo-channel \
  --origin-endpoint-name vertical-video-demo-hls-endpoint \
  --region us-east-1 \
  --query "HlsManifests[0].Url" \
  --output text | sed 's|https://[^/]*/||')

echo "https://${CF_DOMAIN}/${MP_PATH}"
```

Open the URL in:
- **VLC** (File → Open Network Stream)
- **Safari on iPhone** (paste in browser)
- **Online HLS player** (e.g., [hlsplayer.net](https://www.hlsplayer.net))

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| OBS stuck on "Connecting..." | MediaLive channel not running — check status in AWS console |
| "Failed to connect" | Wrong SRT URL or firewall blocking port 9000 |
| High CPU usage (laptop fan loud) | Change CPU preset to "ultrafast" or lower bitrate to 4500 |
| Stream stutters/drops frames | Check upload speed (need 8+ Mbps) — lower bitrate if needed |
| No video in player after 2 minutes | Check MediaLive channel logs in CloudWatch |
| Video is sideways/wrong aspect | Check Output Resolution is 1080x1920, not 1920x1080 |

---

## Quick checklist before going live

- [ ] CloudFormation stack deployed successfully
- [ ] MediaLive channel is RUNNING (not IDLE)
- [ ] OBS Output Resolution is **1080x1920** (vertical)
- [ ] OBS Bitrate is **6000 Kbps**
- [ ] OBS FPS is **30**
- [ ] SRT server URL is correct in Stream settings
- [ ] Video source added to OBS (webcam/screen/file)
- [ ] Upload bandwidth is at least 8 Mbps
- [ ] Tested playback URL in VLC or browser

---

## Stop streaming

1. In OBS, click **Stop Streaming**
2. Stop the MediaLive channel to avoid charges:
   ```bash
   aws medialive stop-channel --channel-id $CHANNEL_ID --region us-east-1
   ```

---

## Tips for demos

- Use a looping video file instead of live camera — more reliable
- Test the full pipeline 30 minutes before the demo
- Have the playback URL ready on a phone to show the vertical output
- For sport content, the AI crop will follow the ball/players automatically
- Keep OBS stats window open (View → Stats) to monitor stream health
