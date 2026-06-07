"""
Highlight Clip Processor - Lambda Function

Triggered by EventBridge when AWS Elemental Inference detects a highlight
moment (goal, tackle, celebration) in the live stream.

Uses MediaPackage V2 time-shifted playback to fetch the exact highlight
window, downloads the segments, builds a VOD HLS manifest, and saves
everything to S3 for on-demand replay.
"""

import boto3
import os
import json
import urllib.request
from datetime import datetime, timedelta, timezone

s3 = boto3.client('s3')
sns = boto3.client('sns')


def handler(event, context):
    """
    Processes Elemental Inference 'Clip Metadata Generated' events.
    """
    print(f"Received event: {json.dumps(event)}")

    detail = event.get('detail', {})
    timescale = detail.get('timescale', 90000)
    start_pts = detail.get('startPts', 0)
    end_pts = detail.get('endPts', 0)
    tags = detail.get('tags', [])
    event_time = event.get('time', '')

    # Calculate clip duration from AI-provided PTS values
    duration_seconds = (end_pts - start_pts) / timescale
    buffer_before = 15  # seconds before the detected event
    buffer_after = 12   # seconds after the detected event

    print(f"AI detected: {tags}, duration: {duration_seconds}s")

    # Wait for segments to be available in MediaPackage buffer
    import time
    time.sleep(10)

    # Calculate time window for the clip
    if event_time:
        detection_time = datetime.fromisoformat(event_time.replace('Z', '+00:00'))
    else:
        detection_time = datetime.now(timezone.utc)

    start_time = detection_time - timedelta(seconds=duration_seconds + buffer_before)
    end_time = detection_time + timedelta(seconds=buffer_after)

    start_iso = start_time.strftime('%Y-%m-%dT%H:%M:%SZ')
    end_iso = end_time.strftime('%Y-%m-%dT%H:%M:%SZ')

    print(f"Fetching clip from {start_iso} to {end_iso}")

    # Create unique clip identifier
    tag_str = '-'.join(tags) if tags else 'highlight'
    timestamp_str = detection_time.strftime('%Y%m%d-%H%M%S')
    clip_id = f"{tag_str}-{timestamp_str}"

    # Build MediaPackage V2 time-shifted playback URL
    endpoint_url = os.environ['ENDPOINT_URL']
    base_endpoint = endpoint_url.split('?')[0]
    time_shifted_url = f"{base_endpoint}?start={start_iso}&end={end_iso}"

    bucket = os.environ['CLIP_BUCKET']

    try:
        # Fetch the time-shifted manifest
        print(f"Fetching time-shifted manifest: {time_shifted_url}")
        req = urllib.request.Request(time_shifted_url)
        with urllib.request.urlopen(req, timeout=30) as response:
            manifest_content = response.read().decode('utf-8')

        print(f"Manifest fetched, length: {len(manifest_content)}")

        # Parse manifest to find segments
        base_url = base_endpoint.rsplit('/', 1)[0] + '/'
        lines = manifest_content.strip().split('\n')

        # Check if this is a master playlist (contains variant streams)
        is_master = any('#EXT-X-STREAM-INF' in line for line in lines)

        if is_master:
            # Find and fetch the variant playlist
            variant_url = None
            for i, line in enumerate(lines):
                if '#EXT-X-STREAM-INF' in line and i + 1 < len(lines):
                    variant_url = lines[i + 1].strip()
                    if not variant_url.startswith('http'):
                        variant_url = base_url + variant_url
                    break

            if not variant_url:
                raise Exception("No variant playlist found in master manifest")

            print(f"Fetching variant playlist: {variant_url}")
            req = urllib.request.Request(variant_url)
            with urllib.request.urlopen(req, timeout=30) as response:
                manifest_content = response.read().decode('utf-8')

            base_url = variant_url.rsplit('/', 1)[0] + '/'
            lines = manifest_content.strip().split('\n')

        # Extract segment URLs and durations
        segment_list = []
        for i, line in enumerate(lines):
            if line.startswith('#EXTINF:'):
                dur = float(line.split(':')[1].rstrip(','))
                if i + 1 < len(lines):
                    seg_url = lines[i + 1].strip()
                    if seg_url.startswith('#'):
                        continue
                    if not seg_url.startswith('http'):
                        seg_url = base_url + seg_url
                    segment_list.append({'url': seg_url, 'duration': dur})

        # Select segments covering the full clip duration
        total_needed = duration_seconds + buffer_before + buffer_after
        selected_segments = []
        collected_duration = 0
        for seg in reversed(segment_list):
            selected_segments.insert(0, seg)
            collected_duration += seg['duration']
            if collected_duration >= total_needed:
                break

        print(f"Selected {len(selected_segments)} segments, duration: {collected_duration}s")

        if not selected_segments:
            raise Exception("No segments found in manifest")

        # Download segments and upload to S3
        clip_prefix = f"clips/{clip_id}"
        segment_files = []

        for idx, seg in enumerate(selected_segments):
            seg_filename = f"segment_{idx:04d}.ts"
            print(f"Downloading segment {idx + 1}/{len(selected_segments)}")

            req = urllib.request.Request(seg['url'])
            with urllib.request.urlopen(req, timeout=30) as response:
                seg_data = response.read()

            s3.put_object(
                Bucket=bucket,
                Key=f"{clip_prefix}/{seg_filename}",
                Body=seg_data,
                ContentType='video/MP2T'
            )
            segment_files.append({
                'filename': seg_filename,
                'duration': seg['duration']
            })

        # Build VOD HLS manifest for the clip
        clip_manifest = "#EXTM3U\n#EXT-X-VERSION:3\n"
        clip_manifest += f"#EXT-X-TARGETDURATION:{int(max(s['duration'] for s in segment_files)) + 1}\n"
        clip_manifest += "#EXT-X-MEDIA-SEQUENCE:0\n"
        clip_manifest += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        for seg in segment_files:
            clip_manifest += f"#EXTINF:{seg['duration']:.6f},\n{seg['filename']}\n"
        clip_manifest += "#EXT-X-ENDLIST\n"

        manifest_key = f"{clip_prefix}/index.m3u8"
        s3.put_object(
            Bucket=bucket,
            Key=manifest_key,
            Body=clip_manifest.encode('utf-8'),
            ContentType='application/vnd.apple.mpegurl'
        )

        total_duration = sum(s['duration'] for s in segment_files)
        print(f"Clip saved: s3://{bucket}/{manifest_key} "
              f"({len(segment_files)} segments, {total_duration:.1f}s)")

        # Send notification
        sns.publish(
            TopicArn=os.environ['SNS_TOPIC_ARN'],
            Subject=f"Highlight: {tag_str}",
            Message=json.dumps({
                'event': tag_str,
                'clipId': clip_id,
                'bucket': bucket,
                'manifestKey': manifest_key,
                'segments': len(segment_files),
                'duration': f"{total_duration:.1f}s",
                'status': 'CLIP_SAVED'
            }, indent=2)
        )

        return {
            'statusCode': 200,
            'clipId': clip_id,
            'duration': total_duration
        }

    except Exception as e:
        print(f"Error processing clip: {str(e)}")
        raise
