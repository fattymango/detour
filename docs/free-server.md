# Get a free server

Free credits can run Detour for months. Offers change, so check each page before signing up.

| | Free | Card needed | When it ends |
|---|---|---|---|
| [AWS](https://aws.amazon.com/free/) | $100, up to $200 with tasks, for 6 months | Yes | Closes, unless you upgrade |
| [Google Cloud](https://docs.cloud.google.com/free/docs/free-cloud-features) | $300 for 90 days | Yes | Stops, unless you upgrade |
| [Azure](https://azure.microsoft.com/en-us/pricing/purchase-options/azure-account) | $200 for 30 days | Yes | Stops, unless you upgrade |
| [Azure for Students](https://azure.microsoft.com/en-us/free/students) | $100 for 12 months, renewable | **No** | Stops, unless you upgrade |

**To stay free:** don't upgrade to a paid plan, use the smallest server, and check its price, its public IP and its outbound data first. VPN traffic counts as outbound data, so video uses credit quickly.

## Option 1: by hand

1. Create a small Ubuntu or Debian server with a public IPv4 address.
2. Firewall: allow TCP **443** from anywhere, and SSH only from your own IP.
3. Follow the [server guide](../server/README.md).
4. [Install the app](../README.md#quick-start) and paste your invite link.

## Option 2: with an AI agent

Connect your agent to your cloud:

- AWS: [Agent Toolkit for AWS](https://github.com/aws/agent-toolkit-for-aws)
- Google Cloud: [gcloud MCP](https://github.com/googleapis/gcloud-mcp) (preview)
- Azure: [Azure MCP Server](https://learn.microsoft.com/azure/developer/azure-mcp-server/)

Sign in yourself, never paste passwords or keys into the chat, and read each action before approving it. Then give it this:

```text
Set up a Detour VPN server in my cloud account, following
https://github.com/fattymango/detour/blob/master/server/README.md

Money:
- First confirm that I'm on a free plan or have credits left. Otherwise stop and ask.
- Never upgrade my plan. Use the cheapest eligible server, and tell me the
  monthly cost of the server, disk, public IP and traffic before creating anything.

Security:
- Inbound: only TCP 443 from anywhere. SSH through the cloud's private access
  (AWS EC2 Instance Connect Endpoint, Google IAP, Azure Bastion if it's free),
  or only from my IP. Nothing else.
- No cloud permissions on the server, encrypted disk, metadata protection on (IMDSv2 on AWS).
- Use the guide's firewall rules, and check that VPN users can't reach the
  server, private networks or the metadata service.

Then:
- Install detour-server for the server's CPU from the project's releases, check
  its checksum, run it as a service, and check that it survives a reboot.
- Create my admin user. Save the invite link in a private local file.
  Don't print it in the chat.
- Tell me how to install the Android app from the releases, and how to stop or delete
  everything.

Ask before opening ports, creating anything that costs credit, or deleting anything.
```

When it's done, paste the invite link in the app. Delete the server when you no longer need it, because even a stopped one can use credit.
