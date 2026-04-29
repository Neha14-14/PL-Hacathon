# AWS setup (safe, no account risk)

## What we use

- **Only:** Amazon Bedrock **InvokeModel** (send a prompt, get text back). No resources created/deleted, no other services.
- **Region:** Mumbai – **ap-south-1** (set in `config/aws_credentials.env`).
- **Credentials:** Stored only in `config/aws_credentials.env` on your laptop. This file is in `.gitignore` and is **never** committed.

## One-time in AWS Console (you do this)

1. Log in to **AWS Console** (your team account).
2. Top-right → switch region to **Asia Pacific (Mumbai) ap-south-1**.
3. Search **Bedrock** → open **Amazon Bedrock**.
4. Left menu → **Model access** (or **Get started**).
5. Find **Claude 3 Haiku** (or the model we use) and click **Enable** for Mumbai. Wait until it shows “Access granted”.

Without this, the first Bedrock call will fail with “model not enabled”. We do not enable it automatically; you do it once in the console.

## Lock / safety

- We only call **InvokeModel** with small prompts. No admin actions, no deleting resources, no changing account settings.
- If you want to be extra safe: set a **billing alert** (e.g. $1) in Billing → Budgets so you get an email if usage spikes.

## Link (Mumbai)

- Bedrock console (after login, set region to Mumbai):  
  https://ap-south-1.console.aws.amazon.com/bedrock/home?region=ap-south-1
