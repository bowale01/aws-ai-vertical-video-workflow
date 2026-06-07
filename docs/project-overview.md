# Project Overview

## Real-Time AI Sports Highlight Pipeline with Vertical Video Transformation

### Summary

This project addresses a growing challenge in live sports broadcasting: delivering content optimised for mobile-first social platforms (TikTok, Instagram Reels, YouTube Shorts) without manual post-production intervention.

Traditional broadcast workflows produce 16:9 widescreen content designed for television. Social platforms require 9:16 vertical video. Converting between these formats in real time — while keeping the relevant action in frame — requires intelligent video analysis that can track subjects dynamically across the frame.

I designed and built a cloud-native pipeline on AWS that ingests a live 16:9 sports broadcast, applies AI-driven smart cropping to follow the action (ball movement, player positioning, key moments), and outputs a 9:16 vertical stream simultaneously to multiple social platforms. The system also detects highlight moments automatically and clips them for on-demand replay.

### Problem Statement

Broadcasters like Sky, DAZN, and BT Sport face pressure to reach younger audiences who consume content primarily on mobile devices in portrait orientation. The current approach — manual editing in post-production — introduces delays that make it unsuitable for live content. A goal scored during a match needs to appear on TikTok within seconds, not hours.

The technical challenge is twofold:
1. Converting aspect ratio in real time without losing the subject of interest
2. Automatically identifying and extracting highlight moments without human intervention

### My Role

I architected the end-to-end system, selected the AWS services, wrote the CloudFormation infrastructure-as-code template, configured the AI inference pipeline, and validated the output quality. I also designed the automated highlight clipping workflow using Lambda with time-shifted playback from MediaPackage v2.

The project was built from scratch — no existing templates or reference implementations were used. I iterated through multiple approaches (SRT vs RTMP ingest, Step Functions vs Lambda clipping, MediaPackage v1 vs v2) before arriving at the current architecture.

### Impact

This pipeline enables a single operator to deliver AI-cropped vertical video to multiple social platforms simultaneously from a standard broadcast feed. What previously required a dedicated production team and post-production workflow now runs autonomously on cloud infrastructure.

The system reduces time-to-publish for highlight clips from minutes (manual editing) to seconds (automated detection and clipping). It scales horizontally — the same architecture supports any number of concurrent channels without additional operational overhead.

For the broadcast industry, this represents a shift from reactive content repurposing to real-time multi-platform delivery, directly addressing the audience fragmentation challenge facing traditional broadcasters.
