# Apple root certificates

`verifySubscriptionPurchase` checks the signature on everything the App Store
Server API returns. The official `@apple/app-store-server-library` needs
Apple's root CA certificates to do that, and refuses to verify without them —
so until these files are present, **Apple purchases fail closed** and nobody is
granted a subscription.

These are public certificates, not secrets. They are committed with the
functions bundle rather than stored in Secret Manager.

## What to put here

Download the DER (`.cer`) files from <https://www.apple.com/certificateauthority/>
and drop them in this directory:

- `AppleComputerRootCertificate.cer`
- `AppleIncRootCertificate.cer`
- `AppleRootCA-G2.cer`
- `AppleRootCA-G3.cer`

Any file in this directory ending in `.cer` or `.der` is loaded. Nothing else
is read, and the list is cached for the lifetime of the function instance.

Verify after deploying by making a sandbox purchase in TestFlight: the log
line `apple purchase verified` means the chain checked out. A
`billing not configured` error means this directory is empty or missing from
the deployed bundle.
