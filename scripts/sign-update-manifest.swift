#!/usr/bin/env swift
// Sign a helper update manifest with Ed25519 (CryptoKit). Skeleton used by helper-release.yml.
//
// Usage: swift scripts/sign-update-manifest.swift <manifest.json> <signature output>
// The private key is read from the UPDATE_SIGNING_KEY environment variable (base64 of the 32-byte raw Ed25519 private key).
// It is never written to disk or printed. The signature is written base64-encoded. The helper embeds only the public key.
//
// Print the public key for embedding: UPDATE_SIGNING_KEY=... swift scripts/sign-update-manifest.swift --public-key
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let keyText = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
      let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
else { fail("UPDATE_SIGNING_KEY is missing or is not a base64 32-byte Ed25519 private key") }

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--public-key" {
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}
guard args.count == 2 else { fail("usage: sign-update-manifest.swift <manifest.json> <signature output>") }
guard let manifest = FileManager.default.contents(atPath: args[0]) else { fail("cannot read \(args[0])") }
guard let signature = try? key.signature(for: manifest) else { fail("signing failed") }
do {
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: args[1]))
} catch {
    fail("cannot write \(args[1])")
}
print("signed \(args[0]) (\(manifest.count) bytes)")
