# ============================================================================
# DEPLOY SCRIPT - AWS Elemental Vertical Video Pipeline
# Run this script after deploying the CloudFormation stack
# ============================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " AWS Vertical Video - Post-Deploy Setup" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: Check SSO login ---
Write-Host "[1/7] Checking AWS credentials..." -ForegroundColor Yellow
$ACCOUNT = aws sts get-caller-identity --query "Account" --output text 2>$null
if (-not $ACCOUNT) {
    Write-Host "ERROR: Not logged in. Run 'aws sso login' first." -ForegroundColor Red
    exit 1
}
Write-Host "  Logged in as account: $ACCOUNT" -ForegroundColor Green

# --- Step 2: Get stack outputs ---
Write-Host "[2/7] Getting stack outputs..." -ForegroundColor Yellow
$CHANNEL_ID = aws cloudformation describe-stacks `
  --stack-name vertical-video-demo `
  --region us-east-1 `
  --query "Stacks[0].Outputs[?OutputKey=='MediaLiveChannelId'].OutputValue" `
  --output text

if (-not $CHANNEL_ID) {
    Write-Host "ERROR: Stack not found. Deploy first with:" -ForegroundColor Red
    Write-Host "  aws cloudformation deploy --template-file medialive-vertical.yaml --stack-name vertical-video-demo --capabilities CAPABILITY_NAMED_IAM --region us-east-1" -ForegroundColor White
    exit 1
}
Write-Host "  MediaLive Channel ID: $CHANNEL_ID" -ForegroundColor Green

# --- Step 3: Get RTMP endpoint ---
Write-Host "[3/7] Getting RTMP endpoint for OBS..." -ForegroundColor Yellow
$RTMP_URL = aws medialive list-inputs `
  --region us-east-1 `
  --query "Inputs[?Name=='vertical-video-demo-rtmp-input'].Destinations[0].Url" `
  --output text

Write-Host "  RTMP URL: $RTMP_URL" -ForegroundColor Green
Write-Host ""
Write-Host "  OBS Settings:" -ForegroundColor White
Write-Host "    Service: Custom" -ForegroundColor White
Write-Host "    Server:  $($RTMP_URL -replace '/stream$', '')" -ForegroundColor White
Write-Host "    Key:     stream" -ForegroundColor White
Write-Host ""

# --- Step 4: Get CloudFront distribution ID ---
Write-Host "[4/7] Getting CloudFront distribution..." -ForegroundColor Yellow
$CF_DOMAIN = aws cloudformation describe-stacks `
  --stack-name vertical-video-demo `
  --region us-east-1 `
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDomain'].OutputValue" `
  --output text

$CF_ID = aws cloudfront list-distributions `
  --query "DistributionList.Items[?DomainName=='$CF_DOMAIN'].Id" `
  --output text

Write-Host "  CloudFront ID: $CF_ID" -ForegroundColor Green
Write-Host "  CloudFront Domain: $CF_DOMAIN" -ForegroundColor Green

# --- Step 5: Fix CloudFront origin domain ---
Write-Host "[5/7] Fixing CloudFront origin domain..." -ForegroundColor Yellow

# Get the actual MediaPackage endpoint domain
$MP_URL = aws mediapackagev2 get-origin-endpoint `
  --channel-group-name vertical-video-demo-channel-group `
  --channel-name vertical-video-demo-channel `
  --origin-endpoint-name vertical-video-demo-hls-endpoint `
  --region us-east-1 `
  --query "HlsManifests[0].Url" `
  --output text

# Extract just the hostname from the URL
$MP_DOMAIN = ([System.Uri]$MP_URL).Host
Write-Host "  MediaPackage domain: $MP_DOMAIN" -ForegroundColor Green

# Get fresh ETag and config
$FRESH_ETAG = aws cloudfront get-distribution-config --id $CF_ID --query "ETag" --output text
aws cloudfront get-distribution-config --id $CF_ID --query "DistributionConfig" --output json | Out-File -FilePath "cf-config.json" -Encoding utf8

# Replace the origin domain
(Get-Content cf-config.json) -replace 'vertical-video-demo-channel-group\.mediapackagev2\.us-east-1\.amazonaws\.com', $MP_DOMAIN | Set-Content cf-config.json

# Verify
$VERIFY = Select-String -Path cf-config.json -Pattern $MP_DOMAIN
if ($VERIFY) {
    Write-Host "  Config updated with correct domain" -ForegroundColor Green
} else {
    Write-Host "  WARNING: Domain replacement may have failed" -ForegroundColor Red
}

# Push update
aws cloudfront update-distribution --id $CF_ID --distribution-config file://cf-config.json --if-match $FRESH_ETAG --output text --query "Distribution.Status" | Out-Null
Write-Host "  CloudFront update submitted (takes 2-3 min to deploy)" -ForegroundColor Green

# --- Step 6: Apply MediaPackage policy ---
Write-Host "[6/7] Applying MediaPackage endpoint policy..." -ForegroundColor Yellow

# Update the policy file with correct distribution ARN
$POLICY = @{
    Version = "2012-10-17"
    Statement = @(
        @{
            Sid = "AllowCloudFrontServicePrincipal"
            Effect = "Allow"
            Principal = @{ Service = "cloudfront.amazonaws.com" }
            Action = "mediapackagev2:GetObject"
            Resource = "arn:aws:mediapackagev2:us-east-1:${ACCOUNT}:channelGroup/vertical-video-demo-channel-group/channel/vertical-video-demo-channel/originEndpoint/vertical-video-demo-hls-endpoint"
            Condition = @{
                StringEquals = @{
                    "AWS:SourceArn" = "arn:aws:cloudfront::${ACCOUNT}:distribution/$CF_ID"
                }
            }
        }
    )
} | ConvertTo-Json -Depth 10

$POLICY | Out-File -FilePath "mediapackage-policy.json" -Encoding utf8

aws mediapackagev2 put-origin-endpoint-policy `
  --channel-group-name vertical-video-demo-channel-group `
  --channel-name vertical-video-demo-channel `
  --origin-endpoint-name vertical-video-demo-hls-endpoint `
  --policy file://mediapackage-policy.json `
  --region us-east-1 2>$null

Write-Host "  MediaPackage policy applied" -ForegroundColor Green

# --- Step 7: Summary ---
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " SETUP COMPLETE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "OBS Stream Settings:" -ForegroundColor White
Write-Host "  Server:     $($RTMP_URL -replace '/stream$', '')" -ForegroundColor Green
Write-Host "  Stream Key: stream" -ForegroundColor Green
Write-Host ""
Write-Host "Playback URL (open in VLC or phone browser):" -ForegroundColor White
$PLAYBACK_PATH = $MP_URL -replace "https://[^/]+", "https://$CF_DOMAIN"
Write-Host "  $PLAYBACK_PATH" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Wait 3 minutes for CloudFront to deploy" -ForegroundColor White
Write-Host "  2. Start MediaLive channel:" -ForegroundColor White
Write-Host "     aws medialive start-channel --channel-id $CHANNEL_ID --region us-east-1" -ForegroundColor White
Write-Host "  3. Wait 60 seconds for channel to reach RUNNING" -ForegroundColor White
Write-Host "  4. Open OBS, set stream settings above, click Start Streaming" -ForegroundColor White
Write-Host "  5. Open playback URL in VLC or phone" -ForegroundColor White
Write-Host ""
Write-Host "To STOP and avoid costs:" -ForegroundColor Red
Write-Host "  aws medialive stop-channel --channel-id $CHANNEL_ID --region us-east-1" -ForegroundColor White
Write-Host ""
